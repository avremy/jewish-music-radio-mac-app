import SwiftUI
import AVFoundation
import AppKit
import ServiceManagement
import Carbon

private let streamURL = URL(string: "https://stream.jewishmusicstream.com:8000/stream")!
private let trackURL = URL(string: "https://jewishmusicstream.com/system/web/currenttrack.html")!

private extension Notification.Name {
    static let toggleRadioPlayback = Notification.Name("JewishMusicStream.togglePlayback")
    static let goLive = Notification.Name("JewishMusicStream.goLive")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURL(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let value = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: value),
              url.scheme == "jewishmusicstream" else { return }
        switch url.host {
        case "toggle": NotificationCenter.default.post(name: .toggleRadioPlayback, object: nil)
        case "live": NotificationCenter.default.post(name: .goLive, object: nil)
        default: break
        }
    }
}

private enum Branding {
    static let logo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "JewishMusicStreamLogo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    static let menuLogo: NSImage? = {
        guard let logo else { return nil }
        let size = NSSize(width: 18, height: 18)
        let output = NSImage(size: size)
        output.lockFocus()
        let destination = NSRect(origin: .zero, size: size)
        NSBezierPath(ovalIn: destination).addClip()
        let sourceSide = min(logo.size.height, logo.size.width)
        let source = NSRect(x: 0, y: 0, width: sourceSide, height: sourceSide)
        logo.draw(in: destination, from: source, operation: .sourceOver, fraction: 1)
        output.unlockFocus()
        output.isTemplate = false
        return output
    }()
}

@MainActor
final class RadioModel: ObservableObject {
    @Published var isPlaying = false
    @Published var title = "JewishMusic Stream"
    @Published var artist = "Live Jewish music"
    @Published var artwork: NSImage?
    @Published var volume: Double = 0.8 { didSet { player.volume = Float(volume) } }
    @Published var status = "Ready"
    @Published var launchAtLogin = false

    private let player = AVPlayer()
    private var timer: Timer?
    private var currentKey = ""
    private var artworkTask: Task<Void, Never>?
    private var toggleObserver: NSObjectProtocol?
    private var goLiveObserver: NSObjectProtocol?

    init() {
        player.volume = Float(volume)
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        timer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshTrack() }
        }
        toggleObserver = NotificationCenter.default.addObserver(forName: .toggleRadioPlayback, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
        }
        goLiveObserver = NotificationCenter.default.addObserver(forName: .goLive, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.goLive() }
        }
        startPlayback()
        Task { await refreshTrack() }
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
            status = "Paused"
        } else {
            startPlayback()
        }
    }

    private func startPlayback() {
        if player.currentItem == nil {
            player.replaceCurrentItem(with: AVPlayerItem(url: streamURL))
        }
        player.play()
        isPlaying = true
        status = "Live"
    }

    func goLive() {
        // Replacing the streaming item drops AVPlayer's buffered, paused position
        // and reconnects at the station's current live edge.
        player.replaceCurrentItem(with: AVPlayerItem(url: streamURL))
        player.play()
        isPlaying = true
        status = "Live"
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            status = "Login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    func refreshTrack() async {
        do {
            var request = URLRequest(url: trackURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 10
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let html = String(data: data, encoding: .utf8) else { return }
            let parsed = Self.parseTrack(html)
            if let name = parsed.title, !name.isEmpty {
                let key = "\(name)|\(parsed.artist ?? "")"
                if key != currentKey {
                    currentKey = key
                    title = name
                    artist = parsed.artist ?? "JewishMusic Stream"
                    artwork = nil
                    artworkTask?.cancel()
                    artworkTask = Task { [weak self] in
                        guard let self else { return }
                        await self.loadArtwork(siteImage: parsed.imageURL, song: name, artist: parsed.artist ?? "")
                    }
                }
            }
        } catch {
            // A failed metadata refresh should never interrupt the radio audio.
            if !isPlaying { status = "Metadata unavailable" }
        }
    }

    nonisolated private static func parseTrack(_ html: String) -> (title: String?, artist: String?, imageURL: URL?) {
        // These stable IDs are more reliable than inferring fields from the page's
        // visual line breaks, which change as links and spans are added.
        let explicitTitle = textInsideElement(id: "currently-playing-title", html: html)
        let explicitArtist = textInsideElement(id: "currently-playing-artist", html: html)

        // The station's currenttrack page contains human-readable "by Artist" and
        // "from Album" fields. Strip scripts/styles first, then parse visible text.
        let cleaned = html.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
        let withBreaks = cleaned.replacingOccurrences(of: "(?i)</(tr|td|div|p|br|h[1-6])[^>]*>", with: "\n", options: .regularExpression)
        let plain = withBreaks.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
        let lines = plain.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var song: String? = explicitTitle
        var artist: String? = explicitArtist
        if (song == nil || artist == nil), let byIndex = lines.firstIndex(where: { $0.lowercased().hasPrefix("by ") }) {
            if artist == nil { artist = String(lines[byIndex].dropFirst(3)).trimmingCharacters(in: .whitespaces) }
            if song == nil, byIndex > 0 { song = lines[byIndex - 1] }
        }
        if song == nil, let idx = lines.firstIndex(where: { $0.localizedCaseInsensitiveContains("Currently Playing") }), idx + 1 < lines.count {
            song = lines[idx + 1]
        }
        if let s = song, s.lowercased() == "time" { song = nil }

        // Prefer the station's own artwork, excluding its generic info icon.
        let pattern = #"(?i)<img\b[^>]*\bsrc\s*=\s*['\"]([^'\"]+)['\"]"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(html.startIndex..., in: html)
        var imageURL: URL?
        for match in regex?.matches(in: html, range: range) ?? [] {
            guard let r = Range(match.range(at: 1), in: html) else { continue }
            let src = String(html[r])
            if src.contains("info.png") || src.lowercased().contains("logo") { continue }
            if let u = URL(string: src, relativeTo: trackURL)?.absoluteURL, ["https", "http"].contains(u.scheme ?? "") {
                imageURL = u; break
            }
        }
        return (song, artist, imageURL)
    }

    nonisolated private static func textInsideElement(id: String, html: String) -> String? {
        let escapedID = NSRegularExpression.escapedPattern(for: id)
        let pattern = "(?is)<([a-z][a-z0-9]*)\\b[^>]*\\bid\\s*=\\s*['\"]" + escapedID + "['\"][^>]*>(.*?)</\\1>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let contentRange = Range(match.range(at: 2), in: html) else { return nil }
        let value = String(html[contentRange])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func loadArtwork(siteImage: URL?, song: String, artist: String) async {
        if let siteImage, let img = await downloadImage(siteImage) {
            if !Task.isCancelled { artwork = img }; return
        }
        // Best-effort fallback. The iTunes catalog won't contain every Jewish release.
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(artist) \(song)"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return }
        let match = results.first { item in
            let found = (item["trackName"] as? String ?? "").lowercased()
            return found.contains(song.lowercased()) || song.lowercased().contains(found) && !found.isEmpty
        }
        guard let path = match?["artworkUrl100"] as? String,
              let url = URL(string: path.replacingOccurrences(of: "100x100", with: "600x600")),
              let img = await downloadImage(url) else { return }
        if !Task.isCancelled { artwork = img }
    }

    private func downloadImage(_ url: URL) async -> NSImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}

struct PlayerPopover: View {
    @ObservedObject var radio: RadioModel
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                if let logo = Branding.logo {
                    Image(nsImage: logo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 205, maxHeight: 58)
                        .accessibilityLabel("JewishMusic Stream")
                } else {
                    Text("JewishMusic Stream").font(.headline)
                }
                Spacer()
                Text("● LIVE").font(.caption2).foregroundStyle(.red)
            }
            Group {
                if let art = radio.artwork {
                    Image(nsImage: art).resizable().scaledToFit()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(.quaternary)
                        Image(systemName: "music.note").font(.system(size: 70)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 220, height: 220).clipShape(RoundedRectangle(cornerRadius: 14))
            Text(radio.title).font(.title3.bold()).lineLimit(2).multilineTextAlignment(.center)
            Text(radio.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 18) {
                Button(action: radio.togglePlayback) {
                    Image(systemName: radio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(radio.isPlaying ? "Pause" : "Play")
                Button(action: radio.goLive) {
                    Label("Go Live", systemImage: "dot.radiowaves.left.and.right")
                }
                .help("Reconnect at the current live point")
            }
            HStack {
                Image(systemName: "speaker.fill")
                Slider(value: $radio.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill")
            }
            Divider()
            HStack {
                Text(radio.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await radio.refreshTrack() } }
                Button("Website") { NSWorkspace.shared.open(URL(string: "https://jewishmusicstream.com/")!) }
            }.font(.caption)
            Toggle("Launch at login", isOn: Binding(get: { radio.launchAtLogin }, set: { radio.setLaunchAtLogin($0) }))
                .font(.caption)
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 290)
    }
}

@main
struct JewishMusicMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var radio = RadioModel()
    var body: some Scene {
        MenuBarExtra {
            PlayerPopover(radio: radio)
        } label: {
            if let art = radio.artwork {
                Image(nsImage: Self.menuImage(art))
            } else if let logo = Branding.menuLogo {
                Image(nsImage: logo)
            } else {
                Image(systemName: "music.note")
            }
        }
        .menuBarExtraStyle(.window)
    }

    private static func menuImage(_ image: NSImage) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let output = NSImage(size: size)
        output.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        output.unlockFocus()
        output.isTemplate = false
        return output
    }
}
