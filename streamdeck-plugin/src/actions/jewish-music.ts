import streamDeck, {
  action,
  KeyAction,
  KeyUpEvent,
  SingletonAction,
  WillAppearEvent,
  WillDisappearEvent
} from "@elgato/streamdeck";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const TRACK_URL = "https://jewishmusicstream.com/system/web/currenttrack.html";
const APP_BUNDLE_ID = "com.local.jewishmusicstream.menubar";
const PROCESS_NAME = "JewishMusicMenuBar";
const REFRESH_INTERVAL = 12_000;

@action({ UUID: "com.avremy.jewishmusicstream.toggle" })
export class JewishMusicAction extends SingletonAction {
  private timer: NodeJS.Timeout | undefined;
  private artworkDataURL: string | undefined;
  private isPlaying = false;

  override async onWillAppear(ev: WillAppearEvent): Promise<void> {
    if (!ev.action.isKey()) return;
    this.isPlaying = await this.isAppRunning();
    await this.refreshArtwork();
    await this.updateKey(ev.action);

    if (!this.timer) {
      this.timer = setInterval(() => void this.refreshAllKeys(), REFRESH_INTERVAL);
    }
  }

  override onWillDisappear(_ev: WillDisappearEvent): void {
    if (this.actions.next().done) {
      clearInterval(this.timer);
      this.timer = undefined;
    }
  }

  override async onKeyUp(ev: KeyUpEvent): Promise<void> {
    if (!ev.action.isKey()) return;
    try {
      if (await this.isAppRunning()) {
        await execFileAsync("/usr/bin/open", ["jewishmusicstream://toggle"]);
        this.isPlaying = !this.isPlaying;
      } else {
        await execFileAsync("/usr/bin/open", ["-b", APP_BUNDLE_ID]);
        this.isPlaying = true;
      }
      await this.updateAllKeys();
    } catch (error) {
      streamDeck.logger.error("Unable to control JewishMusic Stream", error);
      await ev.action.showAlert();
    }
  }

  private async isAppRunning(): Promise<boolean> {
    try {
      await execFileAsync("/usr/bin/pgrep", ["-x", PROCESS_NAME]);
      return true;
    } catch {
      return false;
    }
  }

  private async refreshAllKeys(): Promise<void> {
    this.isPlaying = await this.isAppRunning() && this.isPlaying;
    await this.refreshArtwork();
    await this.updateAllKeys();
  }

  private async refreshArtwork(): Promise<void> {
    try {
      const html = await (await fetch(`${TRACK_URL}?buster=${Date.now()}`)).text();
      const imageTag = html.match(/<img\b[^>]*\bid=["']cpPictureMainSong["'][^>]*>/i)?.[0];
      const source = imageTag?.match(/\bsrc=["']([^"']+)["']/i)?.[1];
      if (!source) return;
      const artworkURL = new URL(source, TRACK_URL);
      const response = await fetch(artworkURL);
      const data = Buffer.from(await response.arrayBuffer()).toString("base64");
      const mime = response.headers.get("content-type") || "image/jpeg";
      this.artworkDataURL = `data:${mime};base64,${data}`;
    } catch (error) {
      streamDeck.logger.warn("Unable to refresh album artwork", error);
    }
  }

  private async updateAllKeys(): Promise<void> {
    const updates: Promise<void>[] = [];
    for (const visibleAction of this.actions) {
      if (visibleAction.isKey()) updates.push(this.updateKey(visibleAction));
    }
    await Promise.all(updates);
  }

  private async updateKey(key: KeyAction): Promise<void> {
    if (!this.artworkDataURL) {
      await key.setImage();
      return;
    }
    const control = this.isPlaying
      ? `<rect x="61" y="116" width="7" height="19" rx="2" fill="white"/><rect x="76" y="116" width="7" height="19" rx="2" fill="white"/>`
      : `<path d="M65 115 L84 125.5 L65 136 Z" fill="white"/>`;
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="144" height="144" viewBox="0 0 144 144"><image href="${this.artworkDataURL}" width="144" height="144" preserveAspectRatio="xMidYMid slice"/><rect y="108" width="144" height="36" fill="rgba(0,0,0,.58)"/>${control}</svg>`;
    await key.setImage(svg);
  }
}
