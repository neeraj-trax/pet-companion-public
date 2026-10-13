import AppKit

/// Small shared UI helpers.
enum UI {
    static func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let f = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = f.fontDescriptor.withDesign(.rounded), let r = NSFont(descriptor: d, size: size) { return r }
        return f
    }
    static let chipFill = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 0.96)
}
