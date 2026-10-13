import AppKit

/// Things you drop on Pet get saved here: ~/Library/Application Support/Pet/Stash
final class StashStore {
    struct RemovedItem {
        let originalURL: URL
        let trashedURL: URL?
    }

    static let shared = StashStore()
    let folder: URL
    private let maxFolderBytes: Int64 = 500 * 1024 * 1024

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("Pet/Stash", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    var count: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.filter { !$0.hasPrefix(".") }.count ?? 0
    }

    /// Visible stash items, newest first. These URLs can be dragged straight into another app.
    var items: [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: Array(keys),
                                                                  options: [.skipsHiddenFiles])) ?? []
        return urls.sorted {
            let a = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    /// Move only copies directly inside Stash to the macOS Trash. The original source is untouched.
    func removeFromStash(_ urls: [URL]) -> [RemovedItem] {
        let fm = FileManager.default
        let stashFolder = folder.standardizedFileURL
        var removed: [RemovedItem] = []
        for url in urls {
            guard url.standardizedFileURL.deletingLastPathComponent() == stashFolder else { continue }
            var trashed: NSURL?
            do {
                try fm.trashItem(at: url, resultingItemURL: &trashed)
                removed.append(RemovedItem(originalURL: url, trashedURL: trashed as URL?))
            } catch {
                continue
            }
        }
        return removed
    }

    /// Put recently removed copies back. A new name is used if another item claimed the old one.
    func restore(_ removed: [RemovedItem]) -> Int {
        let fm = FileManager.default
        var restored = 0
        for item in removed {
            guard let trashedURL = item.trashedURL else { continue }
            do {
                try fm.moveItem(at: trashedURL, to: unique(item.originalURL.lastPathComponent))
                restored += 1
            } catch {
                continue
            }
        }
        return restored
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    /// A short, safe file name from free text.
    private func safeName(_ text: String, fallback: String) -> String {
        var line = text.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        line = line.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while line.hasPrefix(".") { line.removeFirst() }
        line = String(line.prefix(40)).trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? fallback : line
    }

    private func unique(_ name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        var i = 2
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            i += 1
        }
        return url
    }

    // MARK: files (copied off the main thread by the caller)

    func hasFiles(_ pb: NSPasteboard) -> Bool { !fileURLs(pb).isEmpty }

    func fileURLs(_ pb: NSPasteboard) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private func size(of url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey])
        if values?.isDirectory != true {
            return Int64(values?.fileSize ?? values?.totalFileAllocatedSize ?? 0)
        }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
                if total > maxFolderBytes { break }
            }
        }
        return total
    }

    /// Copies files/folders into the stash. Returns a short label, or nil if nothing could be kept.
    func saveFiles(_ urls: [URL]) -> String? {
        var n = 0
        for raw in urls {
            let u = ((try? URL(resolvingAliasFileAt: raw)) ?? raw).resolvingSymlinksInPath()
            if size(of: u) > maxFolderBytes { continue }      // too big to keep a copy of
            let dest = unique(u.lastPathComponent)
            if (try? FileManager.default.copyItem(at: u, to: dest)) != nil { n += 1 }
        }
        guard n > 0 else { return nil }
        return n == 1 ? "file" : "\(n) files"
    }

    // MARK: everything else (fast, main thread is fine)

    /// Saves whatever is on the pasteboard. Returns a short label describing what was kept, or nil.
    func save(from pb: NSPasteboard) -> String? {
        if hasFiles(pb) { return saveFiles(fileURLs(pb)) }

        // Images: keep the original bytes and name when we can
        let imageTypes: [(NSPasteboard.PasteboardType, String)] = [
            (.png, "png"), (NSPasteboard.PasteboardType("public.jpeg"), "jpg"), (.tiff, "tiff")
        ]
        for (type, ext) in imageTypes {
            if let data = pb.data(forType: type), !data.isEmpty {
                var name = "Image \(stamp())"
                if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
                   let u = urls.first, !u.lastPathComponent.isEmpty, u.lastPathComponent.contains(".") {
                    name = safeName(u.deletingPathExtension().lastPathComponent, fallback: name)
                }
                if ext == "tiff", let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: unique("\(name).png"))
                } else {
                    try? data.write(to: unique("\(name).\(ext)"))
                }
                return "image"
            }
        }
        if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: unique("Image \(stamp()).png"))
            return "image"
        }

        // Links: a .webloc that opens in the browser, named after the page title
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let u = urls.first, !u.isFileURL {
            let title = pb.string(forType: NSPasteboard.PasteboardType("public.url-name"))
            saveLink(u, title: title)
            return "link"
        }

        // Text / prompts (a pasted URL becomes a link too)
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")), !trimmed.contains(" "), let u = URL(string: trimmed) {
                saveLink(u, title: nil)
                return "link"
            }
            let name = safeName(text, fallback: "Note")
            try? text.write(to: unique("\(name) \(stamp()).txt"), atomically: true, encoding: .utf8)
            return "note"
        }
        return nil
    }

    private func saveLink(_ u: URL, title: String?) {
        let name = safeName(title ?? u.host ?? "Link", fallback: "Link")
        if let data = try? PropertyListSerialization.data(fromPropertyList: ["URL": u.absoluteString], format: .xml, options: 0) {
            try? data.write(to: unique("\(name).webloc"))
        } else {
            try? (u.absoluteString + "\n").write(to: unique("\(name).txt"), atomically: true, encoding: .utf8)
        }
    }

}
