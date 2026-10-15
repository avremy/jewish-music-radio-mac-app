# JewishMusic Stream — macOS menu-bar player (prototype v0.1)

Native Apple Silicon menu-bar app, with no Dock icon. Plays the live MP3 radio stream and polls the station's current-track page every 12 seconds for song metadata. It reads the station's title, artist, and artwork directly, then uses Apple's iTunes artwork catalog only as a fallback. **Artwork is best effort**, and may not be available for every track.

The popover includes the official JewishMusic Stream logo. Its circular broadcast emblem is used in the menu bar until album artwork is available, and the official JewishMusic Stream mobile artwork is packaged as the macOS application icon.

## Build and run on your Mac

1. Extract the ZIP.
2. Install Apple's Xcode Command Line Tools if necessary: `xcode-select --install`.
3. Right-click `build.command` and choose **Open** (or run `./build.command` from Terminal).
4. A music icon should appear in the top menu bar. Click it, then press Play.

The script compiles the Swift source into `JewishMusic Stream.app` in the same folder, ad-hoc signs it, and opens it. You can move the app to `/Applications` after building. The app uses no third-party dependencies.

## Current limitations

- A future redesign of the station's metadata page could require a parser update.
- macOS Control Center / media-key integration is **not yet implemented**.
- The launch-at-login toggle is most reliable after moving the built app to `/Applications`.

## Technical details

Stream: `https://stream.jewishmusicstream.com:8000/stream`
Metadata page: `https://jewishmusicstream.com/system/web/currenttrack.html`
Minimum macOS: 14; architecture: Apple Silicon (arm64).
