import AppKit

enum AppRingMode: String { case pinned, recent }

/// One chip in the ring: an app, Stash, or "+".
struct RingItem {
    enum Kind { case app(URL, pinned: Bool), stash, add, music(MusicWatcher.Track) }
    let kind: Kind
    let title: String
    let icon: NSImage?

    init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .app(let url, _):
            let real = ((try? URL(resolvingAliasFileAt: url)) ?? url).resolvingSymlinksInPath()
            icon = NSWorkspace.shared.icon(forFile: real.path)
            title = url.deletingPathExtension().lastPathComponent
        case .music(let t):
            icon = t.appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            title = t.caption
        case .stash: icon = nil; title = "Stash"
        case .add:   icon = nil; title = "Add an app"
        }
    }
}

/// Tunable numbers for the ring and its Dock-style magnification.
struct RingConfig {
    var layout = RingLayout(radius: 126, chip: 54, arcDegrees: 160)
    var maxMagnify: CGFloat = 1.35       // scale of the chip right under the cursor
    var spread: CGFloat = 1.5             // how many chips on each side are affected
    var bandInner: CGFloat = 34           // hover band around the ring (inside/outside the radius)
    var bandOuter: CGFloat = 60
    var captionGap: CGFloat = 8
    var margin: CGFloat = 116             // window padding for magnified chips + captions
    var appearSpeed: CGFloat = 4.2        // 1/seconds for the pop-in
    var stagger: CGFloat = 0.45           // how much of the pop-in is stagger (0 = all at once)
    var burst: CGFloat = 0.55             // chips fly in from this fraction of the radius
    var springStiffness: CGFloat = 320    // magnify spring
    var springDamping: CGFloat = 20
    var lift: CGFloat = 9                 // magnified chip rises outward this much
}

/// The ring of app icons around the shark. Draws everything itself and does Dock-like magnification.
final class RingPanel: NSPanel {
    var onLaunch: ((URL) -> Void)?
    var onAdd: (() -> Void)?
    var onStash: (() -> Void)?
    var onRemove: ((URL) -> Void)?
    var onPin: ((URL) -> Void)?
    var onPlayPause: (() -> Void)?
    static let recentLimit = 6
    var appMode: AppRingMode = .pinned
    var recents: [URL] = []
    var displayedAppURLs: [URL] {
        appMode == .recent ? Array(recents.prefix(Self.recentLimit)) : ShortcutStore.shared.apps
    }
    var nowPlaying: MusicWatcher.Track?
    private(set) var isShown = false
    var readyForSelection: Bool {
        guard isShown, ring.appearT >= 1, let first = ring.chipCentre(0) else { return false }
        return ring.chipIndex(at: first) == 0
    }

    var config = RingConfig()
    private let ring = RingView()
    private var lastEdge: ScreenEdge = .bottom
    private var lastScreen = CGRect.zero
    private var hideWork: DispatchWorkItem?
    private var flashUntil = Date.distantPast

    init() {
        let size = RingConfig().layout.radius * 2 + RingConfig().margin * 2
        super.init(contentRect: CGRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        // The ring is a separate panel created after Pet. It must be allowed into
        // another app's full-screen Space when the pointer opens it there.
        collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        ring.panel = self
        contentView = ring
        reload()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: items

    func reload() {
        var items: [RingItem] = []
        if let t = nowPlaying { items.append(RingItem(kind: .music(t))) }
        for url in displayedAppURLs {
            items.append(RingItem(kind: .app(url, pinned: appMode == .pinned)))
        }
        items.append(RingItem(kind: .stash))
        ring.setItems(items)
        if isShown { ring.needsDisplay = true }
    }

    // MARK: show / hide

    /// Centre the ring on Pet's body and open the arc away from its edge.
    func show(near petRect: CGRect, edge: ScreenEdge, screen f: CGRect, centreX: CGFloat? = nil) {
        hideWork?.cancel()
        lastEdge = edge
        lastScreen = f
        let centre = CGPoint(x: centreX ?? petRect.midX, y: petRect.minY + (PetGeometry.bodyCenter.y - PetGeometry.bodyBottom) + 44)
        // find a rotation (and if needed a smaller radius) that keeps every chip on screen and off the pet
        let fit = bestFit(centre: centre, preferred: RingLayout.centreAngle(for: edge), screen: f, petRect: petRect)
        ring.centreAngle = fit.angle
        ring.radiusScale = fit.radiusScale
        ring.arcOverride = fit.arc
        // size the window to the fitted ring so nothing is ever clipped by its own edge
        let reach = config.layout.radius * fit.radiusScale + config.layout.chip * config.maxMagnify / 2 + 70
        let side = (reach * 2).rounded()
        let size = CGSize(width: side, height: side)
        setFrame(CGRect(origin: frame.origin, size: size), display: false)
        ring.frame = CGRect(origin: .zero, size: size)
        ring.edge = edge
        ring.centre = CGPoint(x: size.width / 2, y: size.height / 2)
        setFrameOrigin(CGPoint(x: (centre.x - size.width / 2).rounded(), y: (centre.y - size.height / 2).rounded()))
        ring.prepareForImmediateOpen()
        let pointer = NSEvent.mouseLocation
        let localPointer = CGPoint(x: pointer.x - frame.minX, y: pointer.y - frame.minY)
        ignoresMouseEvents = ring.chipIndex(at: localPointer) == nil
        alphaValue = 1
        orderFrontRegardless()
        isShown = true
    }

    private var closing: Bool { ring.closing }

    func hide() {
        guard isShown else { return }
        isShown = false
        ignoresMouseEvents = true
        ring.closing = true          // the view animates out, then we order out (see tick)
    }

    /// Search rotations, arc widths and radii for a layout with no chip off-screen and none over the pet;
    /// prefer the natural angle, the full arc and the normal radius.
    private func bestFit(centre: CGPoint, preferred: CGFloat, screen f: CGRect, petRect: CGRect) -> (angle: CGFloat, radiusScale: CGFloat, arc: CGFloat) {
        let n = ring.itemCount
        let baseArc = min(360, config.layout.arcDegrees)
        guard n > 0, baseArc < 360 else { return (preferred, 1, baseArc) }
        let chip = config.layout.chip
        let chipR = chip * config.maxMagnify / 2 + 6
        let usable = f.insetBy(dx: chipR + 8, dy: chipR + 30)
        let body = petRect.insetBy(dx: -chipR * 0.6, dy: -chipR * 0.6)
        let baseR = config.layout.radius
        var best: (cost: CGFloat, angle: CGFloat, scale: CGFloat, arc: CGFloat) = (.infinity, preferred, 1, baseArc)
        var arcs: [CGFloat] = [baseArc]
        var a = baseArc - 20
        while a >= 70 { arcs.append(a); a -= 20 }
        for arcDeg in arcs {
            let arc = arcDeg * .pi / 180
            // radius needed so neighbouring chips keep a small gap on the tighter arc
            let step = n > 1 ? arc / CGFloat(n - 1) : arc
            let needed = n > 1 ? (chip + 10) / (2 * sin(step / 2)) : baseR
            let r = max(baseR, needed)
            for stepDeg in stride(from: 0, through: 110, by: 5) {
                for sign in (stepDeg == 0 ? [1] : [1, -1]) as [CGFloat] {
                    let a0 = preferred + sign * CGFloat(stepDeg) * .pi / 180
                    var cost: CGFloat = 0
                    for i in 0..<n {
                        let ai: CGFloat = n == 1 ? a0 : a0 + arc / 2 - step * CGFloat(i)
                        let p = CGPoint(x: centre.x + r * cos(ai), y: centre.y + r * sin(ai))
                        cost += max(0, usable.minX - p.x) + max(0, p.x - usable.maxX)
                        cost += max(0, usable.minY - p.y) + max(0, p.y - usable.maxY)
                        if body.contains(p) { cost += 60 }
                    }
                    cost += CGFloat(stepDeg) * 0.12 + (baseArc - arcDeg) * 0.35 + max(0, r - baseR) * 0.25
                    if cost < best.cost { best = (cost, a0, r / baseR, arcDeg) }
                }
            }
        }
        return (best.angle, best.scale, best.arc)
    }

    /// True while the cursor is somewhere that should keep the ring open (the chips' band or inside it).
    func keepsOpen(for point: CGPoint) -> Bool {
        guard isShown else { return false }
        let localPoint = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        let d = hypot(localPoint.x - ring.centre.x, localPoint.y - ring.centre.y)
        return d < config.layout.radius * ring.radiusScale + config.bandOuter
    }

    /// Advance appear/magnify animations. Called from the pet's animation loop.
    func tick(dt: CGFloat) {
        guard isShown || closing else { return }
        let mouse = NSEvent.mouseLocation
        let local = CGPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
        ring.update(dt: dt, cursor: local)
        if closing && ring.appearT <= 0 {
            ring.closing = false
            orderOut(nil)
            return
        }
        let over = isShown && ring.chipIndex(at: local) != nil
        if over == ignoresMouseEvents { ignoresMouseEvents = !over }
    }

    /// Show a short message above the ring for a moment.
    func flash(_ text: String, for seconds: TimeInterval = 1.8) {
        ring.flashText = text
        flashUntil = Date().addingTimeInterval(seconds)
        ring.needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, Date() >= self.flashUntil else { return }
            self.ring.flashText = ""
            self.ring.needsDisplay = true
        }
    }

    /// Debug: lay the ring out for a pet at `petRect` on screen `f` and return (image, frame) without showing it.
    func previewFit(petRect: CGRect, edge: ScreenEdge, screen f: CGRect, scale: CGFloat = 1) -> (NSImage, CGRect)? {
        show(near: petRect, edge: edge, screen: f)
        orderOut(nil)
        isShown = false
        ring.appearT = 1
        for _ in 0..<30 { ring.update(dt: 1.0 / 60, cursor: CGPoint(x: -999, y: -999)) }
        let b = ring.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * scale), pixelsHigh: Int(b.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = b.size
        ring.cacheDisplay(in: b, to: rep)
        let img = NSImage(size: b.size); img.addRepresentation(rep)
        return (img, frame)
    }

    /// Debug: render the ring as it would look with the cursor over a chip.
    func previewImage(cursorOnChip index: Int, appear: CGFloat = 1, scale: CGFloat = 2) -> NSImage? {
        ring.centre = CGPoint(x: frame.width / 2, y: frame.height / 2)
        ring.edge = .bottom
        ring.centreAngle = RingLayout.centreAngle(for: .bottom)
        ring.radiusScale = 1; ring.arcOverride = nil
        reload()
        ring.appearT = 1
        var cursor = ring.centre
        for _ in 0..<90 {
            cursor = index >= 0 ? (ring.chipCentre(index) ?? ring.centre) : CGPoint(x: -500, y: -500)
            ring.update(dt: 1.0 / 60, cursor: cursor)
        }
        ring.appearT = appear
        ring.needsDisplay = true
        let b = ring.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * scale), pixelsHigh: Int(b.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = b.size
        ring.cacheDisplay(in: b, to: rep)
        let img = NSImage(size: b.size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: actions from the view

    fileprivate func activate(_ item: RingItem) {
        switch item.kind {
        case .app(let url, _): onLaunch?(url)
        case .stash: onStash?()
        case .add: onAdd?()
        case .music: onPlayPause?()
        }
    }

    fileprivate func contextMenu(for item: RingItem, event: NSEvent) {
        guard case .app(let url, let pinned) = item.kind else { return }
        let menu = NSMenu()
        let title = pinned ? "Remove \(item.title) from Pet" : "Pin \(item.title) to Pet"
        let mi = NSMenuItem(title: title, action: #selector(menuTapped(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = [url.path, pinned ? "remove" : "pin"]
        menu.addItem(mi)
        NSMenu.popUpContextMenu(menu, with: event, for: ring)
    }

    @objc private func menuTapped(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String], info.count == 2 else { return }
        let url = URL(fileURLWithPath: info[0])
        if info[1] == "remove" { onRemove?(url) } else { onPin?(url) }
    }
}

/// Draws the chips, magnification, captions. One view, no subviews.
final class RingView: NSView {
    weak var panel: RingPanel?
    var centre = CGPoint.zero
    var centreAngle: CGFloat = .pi / 2
    var edge: ScreenEdge = .bottom
    var appearT: CGFloat = 0
    var closing = false
    var radiusScale: CGFloat = 1
    var arcOverride: CGFloat? = nil
    var itemCount: Int { items.count }
    var captionText = ""
    var flashText = ""
    private var captionAlpha: CGFloat = 0

    private var items: [RingItem] = []
    private var scales: [CGFloat] = []        // current magnification per chip
    private var velocities: [CGFloat] = []
    private var targets: [CGFloat] = []
    private var positions: [CGPoint] = []     // current chip centres (after magnification shift)
    private var hovered: Int? = nil
    private var pressed: Int? = nil

    private var cfg: RingConfig {
        var c = panel?.config ?? RingConfig()
        c.layout.radius *= radiusScale
        if let a = arcOverride { c.layout.arcDegrees = a }
        return c
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func setItems(_ items: [RingItem]) {
        self.items = items
        scales = Array(repeating: 1, count: items.count)
        velocities = Array(repeating: 0, count: items.count)
        targets = scales
        positions = baseAngles().map { angle in point(at: angle, r: cfg.layout.radius) }
    }

    /// Put every chip at its final position before the panel appears, so the
    /// visible ring and its click targets are ready on the same frame.
    func prepareForImmediateOpen() {
        appearT = 1
        closing = false
        captionText = ""
        captionAlpha = 0
        hovered = nil
        pressed = nil
        scales = Array(repeating: 1, count: items.count)
        velocities = Array(repeating: 0, count: items.count)
        targets = scales
        positions = baseAngles().map { angle in point(at: angle, r: cfg.layout.radius) }
        needsDisplay = true
    }

    // MARK: geometry

    private func point(at angle: CGFloat, r: CGFloat) -> CGPoint {
        CGPoint(x: centre.x + r * cos(angle), y: centre.y + r * sin(angle))
    }

    /// Base angles, left end of the fan first, sweeping clockwise.
    private func baseAngles() -> [CGFloat] {
        let n = items.count
        guard n > 0 else { return [] }
        let full = cfg.layout.arcDegrees >= 360
        let arc = (full ? 360 : cfg.layout.arcDegrees) * .pi / 180
        if full { return (0..<n).map { centreAngle + arc / 2 - arc / CGFloat(n) * (CGFloat($0) + 0.5) } }
        if n == 1 { return [centreAngle] }
        let step = arc / CGFloat(n - 1)
        return (0..<n).map { centreAngle + arc / 2 - step * CGFloat($0) }
    }

    private func angle(of p: CGPoint) -> CGFloat { atan2(p.y - centre.y, p.x - centre.x) }

    private func angularDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return abs(d)
    }

    func chipCentre(_ i: Int) -> CGPoint? { positions.indices.contains(i) ? positions[i] : nil }

    func chipIndex(at p: CGPoint) -> Int? {
        for (i, c) in positions.enumerated() {
            let r = cfg.layout.chip * scales[i] / 2 + 2
            if hypot(p.x - c.x, p.y - c.y) <= r { return i }
        }
        return nil
    }

    // MARK: animation

    func update(dt: CGFloat, cursor: CGPoint) {
        guard !items.isEmpty else { return }
        let c = cfg
        let base = baseAngles()
        let n = items.count
        let r = c.layout.radius
        // work in arc length along the fan: chip i's base centre sits at (i + 0.5) * step
        let step = n > 1 ? abs(base[0] - base[1]) * r : c.layout.chip + 12
        let startAngle = base[0] + step / r / 2          // left end of the fan (largest angle)
        if closing { appearT = max(0, appearT - dt * c.appearSpeed * 1.6) }
        else { appearT = min(1, appearT + dt * c.appearSpeed) }

        let d = hypot(cursor.x - centre.x, cursor.y - centre.y)
        let inBand = d > r - c.bandInner && d < r + c.bandOuter
        // cursor position along the arc, clamped to the fan
        var cursorS: CGFloat = -1
        if inBand {
            var da = (startAngle - angle(of: cursor)).truncatingRemainder(dividingBy: 2 * .pi)
            if da < 0 { da += 2 * .pi }
            let s = da * r
            if s <= CGFloat(n) * step + step * 0.5 { cursorS = min(max(s, 0), CGFloat(n) * step) }
        }

        // magnification by distance along the arc (smooth bump), then eased
        for i in 0..<n {
            var t: CGFloat = 1
            if cursorS >= 0 {
                let dist = abs((CGFloat(i) + 0.5) * step - cursorS) / step
                let k = max(0, 1 - dist / c.spread)
                t = 1 + (c.maxMagnify - 1) * (0.5 - 0.5 * cos(k * .pi))
            }
            targets[i] = t
            // damped spring so the magnify has a little life to it
            let accel = (t - scales[i]) * c.springStiffness - velocities[i] * c.springDamping
            velocities[i] += accel * dt
            scales[i] += velocities[i] * dt
        }

        // Dock layout: every chip takes step + extra; the point under the cursor stays put
        let extras = scales.map { ($0 - 1) * c.layout.chip }
        var lefts: [CGFloat] = []
        var acc: CGFloat = 0
        for i in 0..<n { lefts.append(acc); acc += step + extras[i] }
        var offset: CGFloat = 0
        if cursorS >= 0 {
            let k = min(n - 1, Int(cursorS / step))
            let f = min(1, max(0, (cursorS - CGFloat(k) * step) / step))
            offset = lefts[k] + f * (step + extras[k]) - cursorS
        }
        for i in 0..<n {
            let sCentre = lefts[i] + (step + extras[i]) / 2 - offset
            let a = startAngle - sCentre / r
            let lit = max(0, (scales[i] - 1) / max(0.01, c.maxMagnify - 1))
            let target = point(at: a, r: r + c.lift * lit)       // magnified chips rise outward a touch
            positions[i].x += (target.x - positions[i].x) * min(1, dt * 18)
            positions[i].y += (target.y - positions[i].y) * min(1, dt * 18)
        }
        hovered = (cursorS >= 0 && !closing) ? chipIndex(at: cursor) : nil
        if let h = hovered { captionText = items[h].title }
        captionAlpha += ((hovered != nil ? 1 : 0) - captionAlpha) * min(1, dt * 14)
        needsDisplay = true
    }

    /// Per-chip pop-in progress: staggered from the middle of the fan outwards.
    private func appearProgress(_ i: Int) -> CGFloat {
        let c = cfg
        let order = abs(CGFloat(i) - CGFloat(items.count - 1) / 2) / max(1, CGFloat(items.count - 1) / 2)
        let a = (appearT - order * c.stagger) / max(0.05, 1 - c.stagger)
        return max(0, min(1, a))
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let c = cfg
        let base = baseAngles()
        let darkChip = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 0.96)
        for i in items.indices {
            let a = appearProgress(i)
            guard a > 0.01 else { continue }
            // ease-out with a small overshoot, and fly in from the shark
            let e = 1 - pow(1 - a, 3)
            let pop = closing ? e : (e + 0.18 * sin(a * .pi) * (1 - a))
            let d = c.layout.chip * scales[i] * max(0.05, pop)
            let burst = 1 - (1 - c.burst) * (1 - e)          // 0.55 → 1 of the radius
            let p = CGPoint(x: centre.x + (positions[i].x - centre.x) * burst,
                            y: centre.y + (positions[i].y - centre.y) * burst)
            let chipRect = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
            ctx.saveGState()
            ctx.setAlpha(a)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor.black.withAlphaComponent(0.25).cgColor)
            ctx.setFillColor(darkChip.cgColor)
            ctx.fillEllipse(in: chipRect)
            ctx.restoreGState()
            ctx.saveGState()
            ctx.setAlpha(a)
            let lit: CGFloat = (scales[i] - 1) / max(0.01, c.maxMagnify - 1)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10 + 0.25 * lit).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: chipRect.insetBy(dx: 0.5, dy: 0.5))
            if case .app(_, let pinned) = items[i].kind, !pinned { // subtle tick for recently used
                ctx.setFillColor(NSColor(red: 0.55, green: 0.72, blue: 0.92, alpha: 0.9).cgColor)
                ctx.fillEllipse(in: CGRect(x: chipRect.maxX - 8, y: chipRect.maxY - 8, width: 5, height: 5))
            }
            let item = items[i]
            let press: CGFloat = pressed == i ? 0.9 : 1
            let iconSize = d * 0.66 * press
            let iconRect = CGRect(x: p.x - iconSize / 2, y: p.y - iconSize / 2, width: iconSize, height: iconSize)
            if let icon = item.icon {
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
                if case .music(let t) = item.kind {
                    // small play/pause badge
                    let bs = 14 * d / c.layout.chip
                    let br = CGRect(x: chipRect.maxX - bs - 1, y: chipRect.minY + 1, width: bs, height: bs)
                    NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill(); NSBezierPath(ovalIn: br).fill()
                    NSColor(white: 0.9, alpha: 1).setFill()
                    if t.playing {
                        let tri = NSBezierPath()
                        tri.move(to: CGPoint(x: br.minX + bs * 0.36, y: br.minY + bs * 0.28))
                        tri.line(to: CGPoint(x: br.minX + bs * 0.36, y: br.maxY - bs * 0.28))
                        tri.line(to: CGPoint(x: br.maxX - bs * 0.28, y: br.midY)); tri.close(); tri.fill()
                    } else {
                        NSBezierPath(rect: CGRect(x: br.minX + bs * 0.3, y: br.minY + bs * 0.3, width: bs * 0.14, height: bs * 0.4)).fill()
                        NSBezierPath(rect: CGRect(x: br.minX + bs * 0.56, y: br.minY + bs * 0.3, width: bs * 0.14, height: bs * 0.4)).fill()
                    }
                }
            } else {
                let ink = NSColor(white: 0.82, alpha: 1)
                let k = d / c.layout.chip * press
                switch item.kind {
                case .stash:
                    // a little folder
                    let w: CGFloat = 18 * k, h: CGFloat = 13 * k
                    let r = CGRect(x: p.x - w / 2, y: p.y - h / 2 - 1 * k, width: w, height: h)
                    let tab = NSBezierPath(roundedRect: CGRect(x: r.minX, y: r.maxY - 2 * k, width: 8 * k, height: 4 * k), xRadius: 1.5 * k, yRadius: 1.5 * k)
                    ink.withAlphaComponent(0.75).setFill(); tab.fill()
                    let body = NSBezierPath(roundedRect: r, xRadius: 2.5 * k, yRadius: 2.5 * k)
                    ink.setFill(); body.fill()
                    let count = StashStore.shared.count
                    if count > 0 {
                        let badge = NSAttributedString(string: "\(min(count, 99))", attributes: [
                            .font: UI.roundedFont(8 * k, .bold), .foregroundColor: NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)])
                        let bs = badge.size()
                        badge.draw(at: CGPoint(x: r.midX - bs.width / 2, y: r.midY - bs.height / 2 - 0.5 * k))
                    }
                default:
                    let g = NSBezierPath(); g.lineWidth = 2 * k; g.lineCapStyle = .round
                    g.move(to: CGPoint(x: p.x - 6 * k, y: p.y)); g.line(to: CGPoint(x: p.x + 6 * k, y: p.y))
                    g.move(to: CGPoint(x: p.x, y: p.y - 6 * k)); g.line(to: CGPoint(x: p.x, y: p.y + 6 * k))
                    ink.setStroke(); g.stroke()
                }
            }
            ctx.restoreGState()
        }

        // caption pops outward from the hovered chip
        if captionAlpha > 0.02, !captionText.isEmpty, appearT > 0.6, let h = hovered ?? items.indices.first(where: { items[$0].title == captionText }) {
            let p = positions[h]
            let a = base[h]
            let d = c.layout.chip * scales[h]
            ctx.saveGState(); ctx.setAlpha(captionAlpha)
            drawCaption(captionText, anchor: p, angle: a, offset: d / 2 + c.captionGap)
            ctx.restoreGState()
        }
        if !flashText.isEmpty {
            let top = point(at: centreAngle, r: c.layout.radius + c.layout.chip / 2 + 18)
            drawCaption(flashText, anchor: top, angle: centreAngle, offset: 0)
        }
    }

    private func drawCaption(_ text: String, anchor: CGPoint, angle: CGFloat, offset: CGFloat) {
        let str = NSAttributedString(string: text, attributes: [
            .font: UI.roundedFont(11, .medium), .foregroundColor: NSColor(white: 0.9, alpha: 1)])
        let w = min(str.size().width + 18, 220), h: CGFloat = 22
        let cx = anchor.x + cos(angle) * (offset + w / 2)
        let cy = anchor.y + sin(angle) * (offset + h / 2)
        var r = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        r.origin.x = min(max(r.origin.x, 2), bounds.width - w - 2)
        r.origin.y = min(max(r.origin.y, 2), bounds.height - h - 2)
        NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        str.draw(in: CGRect(x: r.minX + 9, y: r.minY + 3.5, width: w - 18, height: h - 6))
    }

    // MARK: mouse

    override func mouseDown(with event: NSEvent) {
        pressed = chipIndex(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let i = chipIndex(at: convert(event.locationInWindow, from: nil))
        if let i, i == pressed { panel?.activate(items[i]) }
        pressed = nil
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let i = chipIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        panel?.contextMenu(for: items[i], event: event)
    }
}
