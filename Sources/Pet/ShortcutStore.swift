import AppKit

/// The list of apps the pet carries. Saved as a small JSON file in Application Support.
final class ShortcutStore {
    static let shared = ShortcutStore()

    private(set) var apps: [URL] = []
    private let fileURL: URL
    private let maxItems = 10

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Pet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("shortcuts.json")
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let paths = try? JSONDecoder().decode([String].self, from: data) {
            apps = paths.map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if apps.count != paths.count { save() }
        } else {
            apps = Self.defaults()
            save()
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(apps.map { $0.path }) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func add(_ url: URL) {
        guard !apps.contains(where: { $0.path == url.path }) else { return }
        apps.append(url)
        if apps.count > maxItems { apps.removeFirst(apps.count - maxItems) }
        save()
    }

    func remove(_ url: URL) {
        apps.removeAll { $0.path == url.path }
        save()
    }

    /// Reorder: take the item at `from` and drop it at index `to` (of the original list).
    func move(from: Int, to: Int) {
        guard apps.indices.contains(from), (0...apps.count).contains(to), from != to else { return }
        let item = apps.remove(at: from)
        apps.insert(item, at: to > from ? to - 1 : to)
        save()
    }

    /// Replace the whole list (de-duplicated, capped).
    func set(_ urls: [URL]) {
        var seen = Set<String>()
        apps = urls.filter { seen.insert($0.path).inserted }
        if apps.count > maxItems { apps = Array(apps.prefix(maxItems)) }
        save()
    }

    /// First-run defaults: a handful of common apps that actually exist on this Mac.
    static func defaults() -> [URL] {
        let candidates = ["Figma", "Safari", "Google Chrome", "Notion", "Slack", "Spotify",
                          "Notes", "Messages", "Finder", "Music", "Mail"]
        let dirs = ["/Applications", "/System/Applications", "/System/Library/CoreServices"]
        var out: [URL] = []
        for name in candidates {
            for dir in dirs {
                let path = "\(dir)/\(name).app"
                if FileManager.default.fileExists(atPath: path) {
                    out.append(URL(fileURLWithPath: path))
                    break
                }
            }
            if out.count == 6 { break }
        }
        return out
    }
}
