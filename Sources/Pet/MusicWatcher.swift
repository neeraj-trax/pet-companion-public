import AppKit

/// What's playing right now (Spotify or Apple Music). No permissions needed: both apps broadcast
/// their state; we only listen. Play/pause on click asks macOS once for permission to control the app.
final class MusicWatcher {
    struct Track {
        var title: String
        var artist: String
        var playing: Bool
        var bundleID: String          // com.spotify.client or com.apple.Music
        var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
        var appName: String { bundleID == "com.spotify.client" ? "Spotify" : "Music" }
        var caption: String {
            let who = artist.isEmpty ? "" : " — \(artist)"
            return "\(playing ? "▶" : "❚❚") \(title)\(who)"
        }
    }

    private(set) var track: Track?
    var onChange: (() -> Void)?

    init() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(spotifyChanged(_:)), name: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil)
        dnc.addObserver(self, selector: #selector(musicChanged(_:)), name: Notification.Name("com.apple.Music.playerInfo"), object: nil)
        dnc.addObserver(self, selector: #selector(musicChanged(_:)), name: Notification.Name("com.apple.iTunes.playerInfo"), object: nil)
    }

    var isPlaying: Bool { track?.playing ?? false }

    @objc private func spotifyChanged(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let state = (info["Player State"] as? String) ?? ""
        if state == "Stopped" { track = nil; onChange?(); return }
        track = Track(title: info["Name"] as? String ?? "", artist: info["Artist"] as? String ?? "",
                      playing: state == "Playing", bundleID: "com.spotify.client")
        onChange?()
    }

    @objc private func musicChanged(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let state = (info["Player State"] as? String) ?? ""
        if state == "Stopped" { track = nil; onChange?(); return }
        track = Track(title: info["Name"] as? String ?? "", artist: info["Artist"] as? String ?? "",
                      playing: state == "Playing", bundleID: "com.apple.Music")
        onChange?()
    }

    /// Toggle play/pause in the player. The first time, macOS asks whether Pet may control that app.
    func playPause() {
        guard let t = track else { return }
        let source = "tell application id \"\(t.bundleID)\" to playpause"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil, let url = t.appURL {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }
}
