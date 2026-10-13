import AppKit

/// A small cushion in the screen corner. The empty bed is click-through;
/// one click on the sleeping dog brings him back out.
final class DogBedPanel: NSPanel {
    static let occupiedSize = CGSize(width: 74, height: 50)
    static let emptySize = CGSize(width: 44, height: 30)
    private let bed = DogBedView(frame: CGRect(origin: .zero, size: emptySize))
    private var lastVisibleFrame: CGRect?
    var onWake: (() -> Void)?

    var occupied: Bool {
        get { bed.occupied }
        set {
            bed.occupied = newValue
            ignoresMouseEvents = !newValue
            let size = newValue ? Self.occupiedSize : Self.emptySize
            setContentSize(size)
            bed.frame = CGRect(origin: .zero, size: size)
            if let lastVisibleFrame { place(in: lastVisibleFrame) }
        }
    }
    var dropHighlighted: Bool {
        get { bed.dropHighlighted }
        set { bed.dropHighlighted = newValue }
    }
    var coat: Coat {
        get { bed.coat }
        set { bed.coat = newValue }
    }

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: Self.emptySize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        bed.onWake = { [weak self] in self?.onWake?() }
        contentView = bed
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func place(in visibleFrame: CGRect) {
        lastVisibleFrame = visibleFrame
        // The transparent art margin stays on-screen while the pillow hugs the corner.
        setFrameOrigin(CGPoint(x: (visibleFrame.maxX - frame.width + 2).rounded(),
                               y: (visibleFrame.minY - 2).rounded()))
    }

    func acceptsDrop(at pointer: CGPoint, dogRect: CGRect) -> Bool {
        // A generous invisible drop target makes the tiny empty pillow usable.
        let target = frame.insetBy(dx: -24, dy: -20)
        if target.contains(pointer) { return true }
        let overlap = target.intersection(dogRect)
        return !overlap.isNull && overlap.width > 28 && overlap.height > 24
    }

    func tick(time: TimeInterval) {
        if occupied { bed.sleepPhase = CGFloat(time) }
    }
}

final class DogBedView: NSView {
    var occupied = false { didSet { needsDisplay = true } }
    var dropHighlighted = false { didSet { needsDisplay = true } }
    var coat: Coat = .hojiro { didSet { needsDisplay = true } }
    var sleepPhase: CGFloat = 0 { didSet { needsDisplay = true } }
    var onWake: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if occupied { onWake?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.interpolationQuality = .high
        // Draw in the original art coordinates, then fit the complete bed into
        // the smaller screen-corner panel without changing the dog's proportions.
        ctx.scaleBy(x: bounds.width / 174, y: bounds.height / 118)
        let ink = NSColor(red: 0.13, green: 0.17, blue: 0.21, alpha: 1)
        let bolster = dropHighlighted
            ? NSColor(red: 0.77, green: 0.86, blue: 0.69, alpha: 1)
            : NSColor(red: 0.65, green: 0.75, blue: 0.61, alpha: 1)
        let inside = NSColor(red: 0.99, green: 0.94, blue: 0.84, alpha: 1)

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.11).cgColor)
        ctx.fillEllipse(in: CGRect(x: 13, y: 3, width: 148, height: 13))

        // A low sage base with a cream hollow for the sleeping dog.
        let cushion = CGMutablePath()
        cushion.move(to: CGPoint(x: 10, y: 32))
        cushion.addCurve(to: CGPoint(x: 39, y: 70), control1: CGPoint(x: 9, y: 51), control2: CGPoint(x: 21, y: 68))
        cushion.addCurve(to: CGPoint(x: 132, y: 70), control1: CGPoint(x: 63, y: 78), control2: CGPoint(x: 111, y: 78))
        cushion.addCurve(to: CGPoint(x: 164, y: 32), control1: CGPoint(x: 153, y: 68), control2: CGPoint(x: 165, y: 51))
        cushion.addCurve(to: CGPoint(x: 134, y: 13), control1: CGPoint(x: 165, y: 17), control2: CGPoint(x: 154, y: 11))
        cushion.addCurve(to: CGPoint(x: 40, y: 13), control1: CGPoint(x: 110, y: 9), control2: CGPoint(x: 64, y: 9))
        cushion.addCurve(to: CGPoint(x: 10, y: 32), control1: CGPoint(x: 20, y: 11), control2: CGPoint(x: 9, y: 17))
        cushion.closeSubpath()
        ctx.addPath(cushion); ctx.setFillColor(bolster.cgColor); ctx.fillPath()
        ctx.addPath(cushion); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(2.5); ctx.strokePath()

        let inset = CGMutablePath()
        inset.move(to: CGPoint(x: 25, y: 39))
        inset.addCurve(to: CGPoint(x: 55, y: 58), control1: CGPoint(x: 26, y: 50), control2: CGPoint(x: 38, y: 57))
        inset.addCurve(to: CGPoint(x: 122, y: 58), control1: CGPoint(x: 74, y: 63), control2: CGPoint(x: 105, y: 63))
        inset.addCurve(to: CGPoint(x: 149, y: 39), control1: CGPoint(x: 139, y: 57), control2: CGPoint(x: 149, y: 50))
        inset.addCurve(to: CGPoint(x: 87, y: 26), control1: CGPoint(x: 143, y: 25), control2: CGPoint(x: 111, y: 26))
        inset.addCurve(to: CGPoint(x: 25, y: 39), control1: CGPoint(x: 61, y: 26), control2: CGPoint(x: 31, y: 25))
        inset.closeSubpath()
        ctx.addPath(inset); ctx.setFillColor(inside.cgColor); ctx.fillPath()
        ctx.addPath(inset); ctx.setStrokeColor(ink.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(1.4); ctx.strokePath()

        if occupied, let atlas = SpriteAtlas.image(for: coat),
           let nap = atlas.cropping(to: SpriteAtlas.rect(of: SpriteFrame(row: 5, col: 1))) {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 12, y: 13, width: 150, height: 100))
            ctx.draw(nap, in: CGRect(x: 29, y: -15, width: 116, height: 126))
            ctx.restoreGState()
        }

        // A low front lip and two curling side bolsters make a little nest.
        let lip = CGMutablePath()
        lip.move(to: CGPoint(x: 17, y: 32))
        lip.addCurve(to: CGPoint(x: 157, y: 32), control1: CGPoint(x: 45, y: 16), control2: CGPoint(x: 129, y: 16))
        lip.addCurve(to: CGPoint(x: 132, y: 12), control1: CGPoint(x: 160, y: 19), control2: CGPoint(x: 149, y: 12))
        lip.addCurve(to: CGPoint(x: 42, y: 12), control1: CGPoint(x: 108, y: 9), control2: CGPoint(x: 66, y: 9))
        lip.addCurve(to: CGPoint(x: 17, y: 32), control1: CGPoint(x: 25, y: 12), control2: CGPoint(x: 14, y: 19))
        lip.closeSubpath()
        ctx.addPath(lip)
        ctx.setFillColor(bolster.cgColor)
        ctx.fillPath()
        ctx.addPath(lip); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(2.2); ctx.strokePath()

        let leftArm = CGMutablePath()
        leftArm.move(to: CGPoint(x: 10, y: 29))
        leftArm.addCurve(to: CGPoint(x: 27, y: 63), control1: CGPoint(x: 8, y: 47), control2: CGPoint(x: 15, y: 61))
        leftArm.addCurve(to: CGPoint(x: 47, y: 52), control1: CGPoint(x: 36, y: 67), control2: CGPoint(x: 44, y: 62))
        leftArm.addCurve(to: CGPoint(x: 56, y: 31), control1: CGPoint(x: 49, y: 42), control2: CGPoint(x: 53, y: 35))
        leftArm.addCurve(to: CGPoint(x: 37, y: 14), control1: CGPoint(x: 56, y: 19), control2: CGPoint(x: 49, y: 15))
        leftArm.addCurve(to: CGPoint(x: 10, y: 29), control1: CGPoint(x: 19, y: 11), control2: CGPoint(x: 10, y: 17))
        leftArm.closeSubpath()
        ctx.addPath(leftArm); ctx.setFillColor(bolster.cgColor); ctx.fillPath()
        ctx.addPath(leftArm); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(2.4); ctx.strokePath()

        let rightArm = CGMutablePath()
        rightArm.move(to: CGPoint(x: 164, y: 29))
        rightArm.addCurve(to: CGPoint(x: 147, y: 63), control1: CGPoint(x: 166, y: 47), control2: CGPoint(x: 159, y: 61))
        rightArm.addCurve(to: CGPoint(x: 127, y: 52), control1: CGPoint(x: 138, y: 67), control2: CGPoint(x: 130, y: 62))
        rightArm.addCurve(to: CGPoint(x: 118, y: 31), control1: CGPoint(x: 125, y: 42), control2: CGPoint(x: 121, y: 35))
        rightArm.addCurve(to: CGPoint(x: 137, y: 14), control1: CGPoint(x: 118, y: 19), control2: CGPoint(x: 125, y: 15))
        rightArm.addCurve(to: CGPoint(x: 164, y: 29), control1: CGPoint(x: 155, y: 11), control2: CGPoint(x: 164, y: 17))
        rightArm.closeSubpath()
        ctx.addPath(rightArm); ctx.setFillColor(bolster.cgColor); ctx.fillPath()
        ctx.addPath(rightArm); ctx.setStrokeColor(ink.cgColor); ctx.setLineWidth(2.4); ctx.strokePath()

        if occupied {
            for (index, mark) in ["z", "Z"].enumerated() {
                let i = CGFloat(index)
                let rise = 2 * sin(sleepPhase * 1.3 - i * 0.6)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10 + i * 3, weight: .semibold),
                    .foregroundColor: NSColor(red: 0.43, green: 0.42, blue: 0.61, alpha: 0.66 + i * 0.11)
                ]
                (mark as NSString).draw(at: CGPoint(x: 128 + i * 13, y: 70 + i * 17 + rise),
                                        withAttributes: attrs)
            }
        }
        ctx.restoreGState()
    }
}

enum DogBedPreview {
    static func render(to url: URL, occupied: Bool = true) {
        let size = occupied ? DogBedPanel.occupiedSize : DogBedPanel.emptySize
        let view = DogBedView(frame: CGRect(origin: .zero, size: size))
        view.occupied = occupied
        view.coat = .hojiro
        view.sleepPhase = 0.5
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
