import AppKit

/// Geometry for the ring of app icons around Pet. Pure math, shared by the preview and the real panel.
struct RingLayout {
    var radius: CGFloat = 100        // distance from the ring centre to each chip centre
    var chip: CGFloat = 44           // chip diameter
    var arcDegrees: CGFloat = 200    // 360 = full ring

    /// Angle (radians) the arc is centred on, so the ring stays on-screen for each edge.
    static func centreAngle(for edge: ScreenEdge) -> CGFloat {
        switch edge {
        case .bottom: return .pi / 2          // fan opens upward
        case .top:    return -.pi / 2         // fan opens downward
        case .left:   return 0                // fan opens to the right
        case .right:  return .pi              // fan opens to the left
        case .free:   return .pi / 2
        }
    }

    func angles(count: Int, edge: ScreenEdge) -> [CGFloat] {
        guard count > 0 else { return [] }
        let full = arcDegrees >= 360
        let arc = (full ? 360 : arcDegrees) * .pi / 180
        let centre = Self.centreAngle(for: edge)
        if full {
            return (0..<count).map { centre + arc * (CGFloat($0) / CGFloat(count)) - arc / 2 + arc / CGFloat(count) / 2 }
        }
        if count == 1 { return [centre] }
        let step = arc / CGFloat(count - 1)
        // first chip on the left end of the fan (larger angle), sweeping clockwise to the right end
        return (0..<count).map { centre + arc / 2 - step * CGFloat($0) }
    }

    func positions(count: Int, edge: ScreenEdge, centre c: CGPoint) -> [CGPoint] {
        angles(count: count, edge: edge).map { CGPoint(x: c.x + radius * cos($0), y: c.y + radius * sin($0)) }
    }

    /// Square size of a window that fits the whole ring plus a margin.
    var windowSize: CGFloat { (radius + chip / 2) * 2 + 40 }
}

/// Debug: renders ring-layout variants around Pet so the layout can be checked without a screen.
enum RingPreview {

    /// The ring fitted for a pet in each corner / edge of a small fake screen.
    static func renderCorners(to url: URL) {
        let panel = RingPanel()
        let screen = CGRect(x: 0, y: 0, width: 640, height: 420)
        let g = PetGeometry.self
        let pw = g.hitRect.width, ph = g.hitRect.height
        let cases: [(String, CGRect, ScreenEdge)] = [
            ("bottom-left", CGRect(x: 4, y: 0, width: pw, height: ph), .bottom),
            ("bottom-middle", CGRect(x: screen.midX - pw / 2, y: 0, width: pw, height: ph), .bottom),
            ("bottom-right", CGRect(x: screen.maxX - pw - 4, y: 0, width: pw, height: ph), .bottom),
            ("left-middle", CGRect(x: 8, y: screen.midY - ph / 2, width: pw, height: ph), .left),
            ("right-low", CGRect(x: screen.maxX - pw - 8, y: 30, width: pw, height: ph), .right),
            ("top-right", CGRect(x: screen.maxX - pw - 4, y: screen.maxY - ph - 2, width: pw, height: ph), .top),
        ]
        let scale: CGFloat = 1.5
        let cols = 3, rows = 2
        let image = NSImage(size: NSSize(width: screen.width * CGFloat(cols) * scale, height: screen.height * CGFloat(rows) * scale), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: scale, y: scale)
            for (n, (name, petRect, edge)) in cases.enumerated() {
                let ox = CGFloat(n % cols) * screen.width, oy = CGFloat(rows - 1 - n / cols) * screen.height
                NSColor(white: 0.94, alpha: 1).setFill()
                CGRect(x: ox + 2, y: oy + 2, width: screen.width - 4, height: screen.height - 4).fill()
                NSColor(red: 0.55, green: 0.72, blue: 0.92, alpha: 0.35).setFill()
                CGRect(x: ox + petRect.minX, y: oy + petRect.minY, width: petRect.width, height: petRect.height).fill()
                if let (img, frame) = panel.previewFit(petRect: petRect, edge: edge, screen: screen) {
                    ctx.saveGState()
                    ctx.clip(to: CGRect(x: ox, y: oy, width: screen.width, height: screen.height))
                    img.draw(in: CGRect(x: ox + frame.minX, y: oy + frame.minY, width: frame.width, height: frame.height),
                             from: .zero, operation: .sourceOver, fraction: 1)
                    ctx.restoreGState()
                }
                NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.darkGray])
                    .draw(at: CGPoint(x: ox + 10, y: oy + screen.height - 22))
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// The first visible frame of the immediately available ring.
    static func renderAppear(to url: URL) {
        let panel = RingPanel()
        let view = PetView(frame: CGRect(origin: .zero, size: PetGeometry.viewSize))
        var pose = PetPose(); pose.mouth = .happy; pose.smile = 1; pose.earPerk = 1; pose.blush = 1; pose.shadow = 1
        view.pose = pose
        let cell = panel.frame.width, scale: CGFloat = 1.5
        let image = NSImage(size: NSSize(width: cell * scale, height: cell * scale), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: scale, y: scale)
            NSColor(white: 0.95, alpha: 1).setFill()
            CGRect(x: 1, y: 1, width: cell - 2, height: cell - 2).fill()
            guard let ring = panel.previewImage(cursorOnChip: -1, appear: 1) else { return false }
            ring.draw(in: CGRect(x: 0, y: 0, width: cell, height: cell), from: .zero, operation: .sourceOver, fraction: 1)
            ctx.saveGState()
            ctx.translateBy(x: cell / 2 - PetGeometry.bodyCenter.x, y: cell / 2 - PetGeometry.bodyCenter.y - 34)
            view.draw(view.bounds)
            ctx.restoreGState()
            NSAttributedString(string: "first frame", attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.darkGray])
                .draw(at: CGPoint(x: 10, y: 8))
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// The real RingView with Dock-style magnification, cursor over chip 2 and chip 5, on light and dark.
    static func renderLive(to url: URL) {
        let panel = RingPanel()
        panel.recents = [URL(fileURLWithPath: "/Applications/Cursor.app")]
        let view = PetView(frame: CGRect(origin: .zero, size: PetGeometry.viewSize))
        var pose = PetPose(); pose.mouth = .happy; pose.smile = 1; pose.earPerk = 1; pose.blush = 1; pose.shadow = 1
        view.pose = pose
        let cell = panel.frame.width, scale: CGFloat = 2
        let cases = [(2, false), (5, false), (2, true), (5, true)]
        let image = NSImage(size: NSSize(width: cell * 2 * scale, height: cell * 2 * scale), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: scale, y: scale)
            for (n, (chip, dark)) in cases.enumerated() {
                let ox = CGFloat(n % 2) * cell, oy = CGFloat(1 - n / 2) * cell
                (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.95, alpha: 1)).setFill()
                CGRect(x: ox + 1, y: oy + 1, width: cell - 2, height: cell - 2).fill()
                guard let ring = panel.previewImage(cursorOnChip: chip) else { continue }
                ring.draw(in: CGRect(x: ox, y: oy, width: cell, height: cell), from: .zero, operation: .sourceOver, fraction: 1)
                ctx.saveGState()
                ctx.translateBy(x: ox + cell / 2 - PetGeometry.bodyCenter.x, y: oy + cell / 2 - PetGeometry.bodyCenter.y - 34)
                view.draw(view.bounds)
                ctx.restoreGState()
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
