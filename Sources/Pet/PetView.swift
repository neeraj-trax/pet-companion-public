import AppKit

/// Draws the dog atlas, with the old vector fallback when the PNG is unavailable.
final class PetView: NSView {
    var pose = PetPose() { didSet { needsDisplay = true } }
    weak var controller: PetController?

    // Palette: coat comes from the pose, features stay cocoa
    private var cream: NSColor { pose.coat.body }
    private var creamShade: NSColor { pose.coat.shade }
    private var outline: NSColor { pose.coat.outline }
    private var cocoa: NSColor { pose.coat.features }
    private let outlineWidth: CGFloat = 2.1

    private func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return a }
        return NSColor(red: a.redComponent + (b.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                       alpha: 1)
    }

    private let blushPink  = NSColor(red: 1.00, green: 0.58, blue: 0.62, alpha: 1)
    private let zzzColor   = NSColor(red: 0.52, green: 0.46, blue: 0.64, alpha: 1)
    private let sparkGold  = NSColor(red: 1.00, green: 0.78, blue: 0.35, alpha: 1)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .URL, .string, .tiff, .png, NSPasteboard.PasteboardType("public.jpeg")])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Drop things on the pet (clipboard stash)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragHover(true)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.dragHover(false) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.dragHover(false)
        return controller?.acceptDrop(sender.draggingPasteboard) ?? false
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) { controller?.petMouseDown(at: NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { controller?.petMouseDragged(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { controller?.petMouseUp(at: NSEvent.mouseLocation) }
    override func rightMouseDown(with event: NSEvent) {
        guard let controller else { return }
        NSMenu.popUpContextMenu(controller.makeMenu(), with: event, for: self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = pose
        let c = PetGeometry.bodyCenter
        let bottom = PetGeometry.bodyBottom

        ctx.saveGState()
        if p.ceiling < bounds.height {
            // never draw over the menu bar when sitting on the top edge
            ctx.clip(to: CGRect(x: 0, y: 0, width: bounds.width, height: max(0, p.ceiling)))
        }
        if p.submerged > 0.01 {
            // Nothing below the water (the screen edge) is drawn, so the body never shows over the Dock.
            ctx.clip(to: CGRect(x: 0, y: p.waterline, width: bounds.width, height: bounds.height - p.waterline))
            drawRipples(ctx, p)
        }

        // User-selected size grows and shrinks around the feet, so Pet keeps standing on
        // the same screen edge instead of floating when the setting changes.
        ctx.translateBy(x: c.x, y: bottom)
        ctx.scaleBy(x: p.displayScale, y: p.displayScale)
        ctx.translateBy(x: -c.x, y: -bottom)

        if p.shadow > 0.01 && p.submerged < 0.5 {
            let w = 70 * p.squashX
            let rect = CGRect(x: c.x - w / 2, y: bottom - 6, width: w, height: 10)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.13 * p.shadow).cgColor)
            ctx.fillEllipse(in: rect)
        }

        if let atlas = SpriteAtlas.image(for: p.coat) {
            drawSprite(ctx, p, atlas: atlas)
            drawZzz(ctx, p)
            drawParticles(ctx, p)
            ctx.restoreGState()
            return
        }

        ctx.saveGState()
        ctx.translateBy(x: c.x, y: bottom + p.bob)
        ctx.scaleBy(x: p.squashX * p.facing, y: p.squashY)
        ctx.translateBy(x: 0, y: PetGeometry.bodyHalfHeight)
        ctx.rotate(by: p.tilt)

        drawTail(ctx, p)
        drawDorsalFin(ctx, p)
        drawBody(ctx, p)
        drawFarFlipper(ctx, p)
        drawNearFlipper(ctx, p)
        drawFace(ctx, p)
        ctx.restoreGState()

        drawZzz(ctx, p)
        drawThought(ctx, p)
        drawParticles(ctx, p)
        ctx.restoreGState()
    }

    private func outlined(_ ctx: CGContext, _ path: CGPath, fill: NSColor, width: CGFloat? = nil) {
        ctx.addPath(path); ctx.setFillColor(fill.cgColor); ctx.fillPath()
        strokeOutline(ctx, path, width: width)
    }

    private func strokeOutline(_ ctx: CGContext, _ path: CGPath, width: CGFloat? = nil) {
        ctx.addPath(path); ctx.setStrokeColor(outline.cgColor); ctx.setLineWidth(width ?? outlineWidth)
        ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.strokePath()
    }

    // MARK: Sprite character

    private var spriteState: SpriteState = .idle
    private var spriteStateStart: CGFloat = 0
    /// Explicit override (used by the pose sheet and icon renderer).
    var spriteFrameOverride: SpriteFrame?

    /// Which animation row the controller's pose asks for. The pose is the only contract with the controller.
    private func inferSpriteState(_ p: PetPose) -> SpriteState {
        if p.held { return .idle }                                                        // paws dangle; don't walk in mid-air
        if p.walk != 0 { return p.walk < 0 ? .runningLeft : .runningRight }               // strolling
        if p.mouth == .chomp && p.flop < 0.5 { return .jumping }                             // poke / drop hover
        if p.mouth == .happy { return .waving }                                             // pill open, welcome
        // Routine thought signals keep the current face. The sprite path does
        // not draw thought bubbles; the waiting row used to appear without context
        // and repeat its sharp up-right look during idle.
        return .idle
    }

    private func drawSprite(_ ctx: CGContext, _ p: PetPose, atlas: CGImage) {
        let napping = p.napping
        let state = napping ? .idle : inferSpriteState(p)
        if state != spriteState { spriteState = state; spriteStateStart = p.time }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var frame: SpriteFrame
        var mirrorGaze = false
        if let o = spriteFrameOverride {
            frame = o
        } else if napping {
            frame = SpriteFrame(row: 5, col: 2)                                              // dog curled up with eyes closed
        } else if p.held {
            frame = SpriteFrame(row: 0, col: 0)                                              // front face and four hanging paws
        } else {
            frame = SpriteAtlas.frame(for: state, elapsed: TimeInterval(p.time - spriteStateStart), reducedMotion: reduced, loop: p.walk != 0)
            let lookMag = hypot(p.look.x, p.look.y)
            if state == .idle, lookMag > 0.5 {                                              // directional gaze
                let look = SpriteAtlas.lookView(dx: p.look.x, dyUp: p.look.y)
                frame = look.frame
                mirrorGaze = look.mirrored
            } else if state == .idle, p.eyeOpen < 0.4 || p.eyeStyle == .closed {
                frame = SpriteFrame(row: 0, col: 1)                                        // blink while standing
            }
        }
        guard let cell = atlas.cropping(to: SpriteAtlas.rect(of: frame)) else { return }

        let s = PetGeometry.spriteScale
        // When held, the upper body stays near the grab point and the paws swing below it.
        let pivot = p.held
            ? CGPoint(x: PetGeometry.bodyCenter.x, y: PetGeometry.bodyBottom + 82)
            : CGPoint(x: PetGeometry.bodyCenter.x, y: PetGeometry.bodyBottom)
        ctx.saveGState()
        ctx.translateBy(x: pivot.x, y: pivot.y + p.bob)
        if !napping {
            ctx.scaleBy(x: p.squashX, y: p.squashY)
            ctx.rotate(by: p.tilt * (p.held ? 1 : 0.6))
        }
        ctx.translateBy(x: -pivot.x, y: -pivot.y)
        if mirrorGaze {
            ctx.translateBy(x: 2 * pivot.x, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        ctx.interpolationQuality = .high
        let o = PetGeometry.spriteCellOrigin
        ctx.draw(cell, in: CGRect(x: o.x, y: o.y, width: SpriteAtlas.cell.width * s, height: SpriteAtlas.cell.height * s))
        if p.held { drawHeldCollar(ctx) }
        ctx.restoreGState()
    }

    private func drawHeldCollar(_ ctx: CGContext) {
        let ink = NSColor(red: 0.13, green: 0.17, blue: 0.21, alpha: 1)
        let strap = CGMutablePath()
        strap.move(to: CGPoint(x: 62, y: 72))
        strap.addQuadCurve(to: CGPoint(x: 108, y: 72), control: CGPoint(x: 85, y: 60))
        ctx.addPath(strap)
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(6)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.addPath(strap)
        ctx.setStrokeColor(NSColor(red: 0.79, green: 0.48, blue: 0.34, alpha: 1).cgColor)
        ctx.setLineWidth(3.7)
        ctx.strokePath()
        ctx.setFillColor(ink.cgColor)
        ctx.fillEllipse(in: CGRect(x: 81.5, y: 62, width: 7, height: 7))
        ctx.setFillColor(NSColor(red: 0.96, green: 0.79, blue: 0.42, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: 83, y: 63.5, width: 4, height: 4))
    }

    // MARK: Character
    //
    // One canonical shark, drawn in body-local coords (origin at bodyCenter, y up, face toward +x).
    // Mirroring for `facing` happens in draw(_:) so every part flips together.
    // Order: tail, far flipper, dorsal fin (all behind) → body with cream muzzle/belly → face → near flipper.

    /// The controller's `earPerk` idles around 0.35 (rising with mouse proximity) and hits 1 when excited.
    /// 0 = fully relaxed, 1 = raised.
    private func perk(_ p: PetPose) -> CGFloat { max(0, min(1, (p.earPerk - 0.3) / 0.7)) }

    private func drawBody(_ ctx: CGContext, _ p: PetPose) {
        let path = PetGeometry.bodyPath()
        ctx.addPath(path); ctx.setFillColor(cream.cgColor); ctx.fillPath()

        // cream muzzle + belly wrapping the front three-quarters: starts under the front eye, bulges up between
        // the eyes, dips under the far eye, then runs down the back edge of the belly to the ground.
        let d = 6 * p.flop
        let belly = CGMutablePath()
        belly.move(to: CGPoint(x: 44, y: 14 - d))
        belly.addCurve(to: CGPoint(x: 12, y: 25 - d), control1: CGPoint(x: 32, y: 19 - d), control2: CGPoint(x: 21, y: 25 - d))
        belly.addCurve(to: CGPoint(x: -7, y: 14 - d), control1: CGPoint(x: 4, y: 25 - d), control2: CGPoint(x: -3, y: 19 - d))
        belly.addCurve(to: CGPoint(x: -25, y: -14), control1: CGPoint(x: -15, y: 6 - d), control2: CGPoint(x: -25, y: -2))
        belly.addCurve(to: CGPoint(x: -14, y: -60), control1: CGPoint(x: -25, y: -30), control2: CGPoint(x: -22, y: -50))
        belly.addLine(to: CGPoint(x: 44, y: -60))
        belly.closeSubpath()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.addPath(belly); ctx.setFillColor(creamShade.cgColor); ctx.fillPath()
        ctx.restoreGState()

        strokeOutline(ctx, path)
    }

    private func drawDorsalFin(_ ctx: CGContext, _ p: PetPose) {
        // Sits on the back of the head, leaning back; perks up when excited, lies flat for a nap. Base hidden under the head.
        let k = perk(p)
        let tip = CGPoint(x: -18 - 3 * (1 - k) - 22 * p.flop + p.finSway,
                          y: 61 + 5 * k - 14 * p.flop)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 12, y: 26))
        path.addCurve(to: tip, control1: CGPoint(x: 16, y: 50), control2: CGPoint(x: tip.x + 12, y: tip.y + 2))      // leading edge, convex
        path.addCurve(to: CGPoint(x: -31, y: 22), control1: CGPoint(x: tip.x + 1, y: tip.y - 12), control2: CGPoint(x: -24, y: 34))  // trailing edge, scooped
        path.closeSubpath()
        outlined(ctx, path, fill: cream)
    }

    /// A small leaf-shaped flipper pointing along +x from its root at the origin.
    private func flipperPath(length L: CGFloat, halfWidth w: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: w * 0.7))
        path.addCurve(to: CGPoint(x: L, y: 0), control1: CGPoint(x: L * 0.3, y: w * 1.25), control2: CGPoint(x: L * 0.72, y: w * 0.7))
        path.addCurve(to: CGPoint(x: 0, y: -w * 0.7), control1: CGPoint(x: L * 0.72, y: -w * 0.7), control2: CGPoint(x: L * 0.3, y: -w * 1.25))
        path.addCurve(to: CGPoint(x: 0, y: w * 0.7), control1: CGPoint(x: -w * 0.6, y: -w * 0.7), control2: CGPoint(x: -w * 0.6, y: w * 0.7))
        path.closeSubpath()
        return path
    }

    private func drawFlipper(_ ctx: CGContext, root: CGPoint, side: CGFloat, angle: CGFloat, length: CGFloat, halfWidth: CGFloat = 8) {
        ctx.saveGState()
        ctx.translateBy(x: root.x, y: root.y)
        ctx.scaleBy(x: side, y: 1)
        ctx.rotate(by: angle)
        outlined(ctx, flipperPath(length: length, halfWidth: halfWidth), fill: cream)
        ctx.restoreGState()
    }

    /// The far flipper (back side): hangs down and back from mid-body.
    private func drawFarFlipper(_ ctx: CGContext, _ p: PetPose) {
        let angle = -0.85 + 1.3 * perk(p) - 0.3 * p.flop
        drawFlipper(ctx, root: CGPoint(x: -28, y: 2), side: -1, angle: angle, length: 26, halfWidth: 7)
    }

    /// The near flipper (front): a little leaf hanging down along the front of the belly.
    private func drawNearFlipper(_ ctx: CGContext, _ p: PetPose) {
        let angle = -1.1 + 1.5 * perk(p) - 0.3 * p.flop
        drawFlipper(ctx, root: CGPoint(x: 26, y: -11), side: 1, angle: angle, length: 21, halfWidth: 6.5)
    }

    private func drawTail(_ ctx: CGContext, _ p: PetPose) {
        // Short tail stock from the lower back into a two-lobed caudal fin (upper lobe larger); swings as one piece.
        let swing = sin(p.tailPhase) * 0.14 * p.tailWag + 0.32 * p.flop
        ctx.saveGState()
        ctx.translateBy(x: -30, y: -16)
        ctx.rotate(by: swing)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 10, y: 9))
        path.addCurve(to: CGPoint(x: -12, y: 6), control1: CGPoint(x: -1, y: 9.5), control2: CGPoint(x: -8, y: 7.5))
        path.addCurve(to: CGPoint(x: -29, y: 21), control1: CGPoint(x: -19, y: 9), control2: CGPoint(x: -27, y: 17))     // upper lobe
        path.addCurve(to: CGPoint(x: -16, y: 0), control1: CGPoint(x: -31, y: 15), control2: CGPoint(x: -21, y: 5))
        path.addCurve(to: CGPoint(x: -26, y: -19), control1: CGPoint(x: -19, y: -6), control2: CGPoint(x: -26, y: -15))  // lower lobe
        path.addCurve(to: CGPoint(x: -12, y: -6), control1: CGPoint(x: -24, y: -20), control2: CGPoint(x: -16, y: -10))
        path.addCurve(to: CGPoint(x: 10, y: -9), control1: CGPoint(x: -8, y: -7.5), control2: CGPoint(x: -1, y: -9.5))
        path.closeSubpath()
        outlined(ctx, path, fill: cream)
        ctx.restoreGState()
    }

    private func drawFace(_ ctx: CGContext, _ p: PetPose) {
        let lookX = p.look.x * p.facing * 3, lookY = p.look.y * 2
        let drop = 6 * p.flop                     // napping: the face settles lower on the flattened body
        let eyeY = 19 + lookY - drop

        // gills: two faint curved slits on the blue behind the far eye
        ctx.setStrokeColor(outline.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1.3)
        ctx.setLineCap(.round)
        for i in 0..<2 {
            let x = -24 - CGFloat(i) * 3.6
            let y0 = 14 - CGFloat(i) * 1.5 - drop, y1 = 2 - CGFloat(i) * 0.5 - drop
            ctx.move(to: CGPoint(x: x, y: y0))
            ctx.addQuadCurve(to: CGPoint(x: x, y: y1), control: CGPoint(x: x - 2.4, y: (y0 + y1) / 2))
        }
        ctx.strokePath()

        // blush (only really shows when happy)
        ctx.setFillColor(blushPink.withAlphaComponent(0.36 * max(0, p.blush - 0.5) * 2).cgColor)
        ctx.fillEllipse(in: CGRect(x: 23, y: 9 - drop, width: 11, height: 6))
        ctx.fillEllipse(in: CGRect(x: -15, y: 8 - drop, width: 11, height: 6))

        // eyes: two small dots, the front one near the edge of the head
        for ex0: CGFloat in [-7, 29] {
            let ex = ex0 + lookX, ey = eyeY
            switch p.eyeStyle {
            case .open:
                let ry = max(0.5, 3.3 * p.eyeOpen)
                ctx.setFillColor(cocoa.cgColor)
                ctx.fillEllipse(in: CGRect(x: ex - 3.2, y: ey - ry, width: 6.4, height: ry * 2))
                if p.eyeOpen > 0.55 {
                    ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
                    ctx.fillEllipse(in: CGRect(x: ex - 1.9, y: ey + 0.4, width: 1.9, height: 1.9))
                }
            case .happy:
                ctx.setStrokeColor(cocoa.cgColor); ctx.setLineWidth(2); ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: ex - 3.8, y: ey - 1))
                ctx.addQuadCurve(to: CGPoint(x: ex + 3.8, y: ey - 1), control: CGPoint(x: ex, y: ey + 4.5))
                ctx.strokePath()
            case .closed:
                ctx.setStrokeColor(cocoa.cgColor); ctx.setLineWidth(1.8); ctx.setLineCap(.round)
                ctx.move(to: CGPoint(x: ex - 3.8, y: ey + 1))
                ctx.addQuadCurve(to: CGPoint(x: ex + 3.8, y: ey + 1), control: CGPoint(x: ex, y: ey - 3))
                ctx.strokePath()
            }
        }

        drawMouth(ctx, p, center: CGPoint(x: 12 + lookX * 0.3, y: 7 - drop))
    }

    private let tonguePink = NSColor(red: 0.93, green: 0.50, blue: 0.55, alpha: 1)

    private func drawMouth(_ ctx: CGContext, _ p: PetPose, center m: CGPoint) {
        switch p.mouth {
        case .neutral, .happy:
            // tiny friendly smile that opens into a round happy mouth as `smile` rises
            let s = max(0, min(1, p.smile))
            let mw = 22 + 6 * s, mh = 11 * s, sag: CGFloat = 3.5 - 2.5 * s
            let l = CGPoint(x: m.x - mw / 2, y: m.y + 1), r = CGPoint(x: m.x + mw / 2, y: m.y + 1)
            let bowl = CGMutablePath()
            bowl.move(to: l)
            bowl.addQuadCurve(to: r, control: CGPoint(x: m.x, y: m.y + 1 - sag))                       // upper lip: gentle smile
            bowl.addCurve(to: l, control1: CGPoint(x: r.x, y: m.y - sag - mh * 1.4), control2: CGPoint(x: l.x, y: m.y - sag - mh * 1.4))
            bowl.closeSubpath()
            if s > 0.02 { ctx.addPath(bowl); ctx.setFillColor(cocoa.cgColor); ctx.fillPath() }
            if s > 0.25 {
                ctx.saveGState(); ctx.addPath(bowl); ctx.clip()
                ctx.setFillColor(tonguePink.cgColor)
                ctx.fillEllipse(in: CGRect(x: m.x - mw * 0.3, y: m.y - mh - 3, width: mw * 0.6, height: mh * 0.75))
                ctx.restoreGState()
            }
            ctx.addPath(bowl); ctx.setStrokeColor(cocoa.cgColor); ctx.setLineWidth(1.4 + 0.4 * s); ctx.setLineJoin(.round); ctx.setLineCap(.round); ctx.strokePath()
            drawFangs(ctx, at: [CGPoint(x: m.x - 5.5 - 2 * s, y: m.y - 0.4 - sag * 0.4), CGPoint(x: m.x + 5.5 + 2 * s, y: m.y - 0.4 - sag * 0.4)], size: 3.6)

        case .sleepy:
            let sm = CGMutablePath()
            sm.move(to: CGPoint(x: m.x - 4.5, y: m.y + 0.5))
            sm.addQuadCurve(to: CGPoint(x: m.x + 4.5, y: m.y + 0.5), control: CGPoint(x: m.x, y: m.y - 3.5))
            ctx.addPath(sm); ctx.setStrokeColor(cocoa.cgColor); ctx.setLineWidth(1.8); ctx.setLineCap(.round); ctx.strokePath()
            drawFangs(ctx, at: [CGPoint(x: m.x + 2, y: m.y - 1)], size: 2.6)

        case .surprised:
            let o = CGPath(ellipseIn: CGRect(x: m.x - 4.2, y: m.y - 7, width: 8.4, height: 11), transform: nil)
            ctx.addPath(o); ctx.setFillColor(cocoa.cgColor); ctx.fillPath()
            ctx.saveGState(); ctx.addPath(o); ctx.clip()
            ctx.setFillColor(tonguePink.cgColor)
            ctx.fillEllipse(in: CGRect(x: m.x - 3, y: m.y - 9, width: 6, height: 5.5))
            ctx.restoreGState()
            strokeOutline(ctx, o, width: 1.7)

        case .chomp:
            // the big one: wide rounded jaws, pink tongue, a row of teeth top and bottom, all clipped inside
            let open = max(0, min(1, p.chomp))
            let mw = 26 + 16 * open, mh = 7 + 22 * open
            let rect = CGRect(x: m.x - mw / 2, y: m.y + 4 - mh, width: mw, height: mh)
            let mouth = CGPath(roundedRect: rect, cornerWidth: min(mw * 0.42, mh * 0.5), cornerHeight: min(mw * 0.42, mh * 0.5), transform: nil)
            ctx.addPath(mouth); ctx.setFillColor(cocoa.cgColor); ctx.fillPath()
            ctx.saveGState(); ctx.addPath(mouth); ctx.clip()
            ctx.setFillColor(tonguePink.cgColor)
            ctx.fillEllipse(in: CGRect(x: m.x - mw * 0.32, y: rect.minY - 2, width: mw * 0.64, height: mh * 0.55))
            if open > 0.2 {
                ctx.setFillColor(NSColor.white.cgColor)
                let th = min(7, mh * 0.34)
                let teeth = CGMutablePath()
                let n = 4
                let step = (mw - 10) / CGFloat(n)
                let x0 = rect.minX + 5
                for i in 0..<n {                 // top row hangs down
                    let a = x0 + CGFloat(i) * step
                    teeth.move(to: CGPoint(x: a, y: rect.maxY + 1))
                    teeth.addLine(to: CGPoint(x: a + step / 2, y: rect.maxY - th))
                    teeth.addLine(to: CGPoint(x: a + step, y: rect.maxY + 1))
                    teeth.closeSubpath()
                }
                for i in 0..<(n - 1) {           // bottom row points up
                    let a = x0 + step / 2 + CGFloat(i) * step
                    teeth.move(to: CGPoint(x: a, y: rect.minY - 1))
                    teeth.addLine(to: CGPoint(x: a + step / 2, y: rect.minY + th * 0.8))
                    teeth.addLine(to: CGPoint(x: a + step, y: rect.minY - 1))
                    teeth.closeSubpath()
                }
                ctx.addPath(teeth); ctx.fillPath()
                ctx.addPath(teeth); ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.2); ctx.setLineJoin(.round); ctx.strokePath()
            }
            ctx.restoreGState()
            strokeOutline(ctx, mouth, width: 2)
        }
    }

    /// Little white fangs hanging from a mouth line.
    private func drawFangs(_ ctx: CGContext, at points: [CGPoint], size: CGFloat) {
        let path = CGMutablePath()
        for pt in points {
            path.move(to: CGPoint(x: pt.x - size / 2, y: pt.y + 0.6))
            path.addLine(to: CGPoint(x: pt.x, y: pt.y - size))
            path.addLine(to: CGPoint(x: pt.x + size / 2, y: pt.y + 0.6))
            path.closeSubpath()
        }
        ctx.addPath(path); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(cocoa.cgColor); ctx.setLineWidth(1); ctx.setLineJoin(.round); ctx.strokePath()
    }

    private func drawRipples(_ ctx: CGContext, _ p: PetPose) {
        // Two soft rings on the waterline around the fin, plus a short wake behind it while cruising.
        let c = PetGeometry.bodyCenter
        let y = p.waterline + 1.5
        let a = 0.9 * p.submerged
        ctx.setStrokeColor(blend(cream, outline, 0.25).withAlphaComponent(a).cgColor)
        ctx.setLineWidth(1.8)
        ctx.setLineCap(.round)
        for s: CGFloat in [-1, 1] {
            let phase = p.time * 2.2 + (s > 0 ? 1.3 : 0)
            let x = c.x + s * (22 + 5 * sin(phase))
            ctx.move(to: CGPoint(x: x - 10, y: y)); ctx.addQuadCurve(to: CGPoint(x: x + 10, y: y), control: CGPoint(x: x, y: y + 3.2))
            let x2 = c.x + s * (42 + 5 * sin(phase * 0.8 + 2))
            ctx.move(to: CGPoint(x: x2 - 7, y: y)); ctx.addQuadCurve(to: CGPoint(x: x2 + 7, y: y), control: CGPoint(x: x2, y: y + 2.6))
        }
        ctx.strokePath()
        if p.wake > 0.05 {
            let len = 30 * p.wake
            let x0 = c.x - p.facing * 18, x1 = x0 - p.facing * len
            ctx.setStrokeColor(blend(cream, outline, 0.25).withAlphaComponent(a * 0.6 * p.wake).cgColor)
            ctx.setLineWidth(1.4)
            ctx.move(to: CGPoint(x: x0, y: y + 1)); ctx.addQuadCurve(to: CGPoint(x: x1, y: y + 1), control: CGPoint(x: (x0 + x1) / 2, y: y + 4))
            ctx.strokePath()
        }
    }

    private func drawThought(_ ctx: CGContext, _ p: PetPose) {
        guard p.thoughtAlpha > 0.01, !p.thought.isEmpty else { return }
        let a = p.thoughtAlpha
        let c = PetGeometry.bodyCenter
        let side = p.facing
        let head = CGPoint(x: c.x + side * 26, y: topNow(p) - 10)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: roundedFont(13, .semibold),
            .foregroundColor: NSColor(red: 0.35, green: 0.30, blue: 0.40, alpha: a)
        ]
        let str = NSAttributedString(string: p.thought, attributes: attrs)
        let size = str.size()
        let bw = max(30, size.width + 14), bh: CGFloat = 26
        var bx = c.x + side * 36 - bw / 2
        bx = min(max(bx, 2), bounds.width - bw - 2)
        let bubble = CGRect(x: bx, y: min(head.y + 22 + 2 * sin(p.time * 2), bounds.height - bh - 2), width: bw, height: bh)
        ctx.saveGState()
        ctx.setAlpha(a)
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor.black.withAlphaComponent(0.15).cgColor)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
        ctx.fillEllipse(in: CGRect(x: head.x + side * 6 - 2.5, y: head.y + 8, width: 5, height: 5))
        ctx.fillEllipse(in: CGRect(x: head.x + side * 12 - 3.5, y: head.y + 15, width: 7, height: 7))
        ctx.addPath(CGPath(roundedRect: bubble, cornerWidth: 13, cornerHeight: 13, transform: nil)); ctx.fillPath()
        ctx.restoreGState()
        str.draw(at: CGPoint(x: bubble.midX - size.width / 2, y: bubble.midY - size.height / 2 + 0.5))
    }

    /// Top of the drawn character (dog ears for the sprite, fin-less body for the shark).
    private func topNow(_ p: PetPose) -> CGFloat { p.bodyTopNow + (SpriteAtlas.image != nil ? PetGeometry.earHeight * p.squashY : 0) }

    private func drawZzz(_ ctx: CGContext, _ p: PetPose) {
        guard p.zzz > 0.01 else { return }
        let c = PetGeometry.bodyCenter
        let dogNap = SpriteAtlas.image != nil && p.napping
        let direction: CGFloat = dogNap ? 1 : p.facing
        var base = CGPoint(x: c.x + p.facing * 26, y: topNow(p) - 12)
        if dogNap {
            base = CGPoint(x: c.x + 28, y: PetGeometry.bodyBottom + 66)
        } else if p.flop > 0.5 {   // vector fallback: head is off to the side
            base = CGPoint(x: c.x + p.facing * (PetGeometry.characterHalfHeight - 10), y: PetGeometry.bodyBottom + PetGeometry.bodyHalfWidth * 2 - 6)
        }
        for i in 0..<3 {
            let phase = (p.time * 0.45 + CGFloat(i) / 3).truncatingRemainder(dividingBy: 1)
            let alpha = p.zzz * min(1, phase * 3) * (1 - phase)
            let size = 10 + 9 * phase
            let pt = CGPoint(x: base.x + direction * (8 + 24 * phase) + 4 * sin(phase * 7),
                             y: base.y + 34 * phase)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: roundedFont(size, .bold),
                .foregroundColor: zzzColor.withAlphaComponent(alpha)
            ]
            NSAttributedString(string: "z", attributes: attrs).draw(at: pt)
        }
    }

    private func drawParticles(_ ctx: CGContext, _ p: PetPose) {
        for q in p.particles {
            let k = q.life / q.maxLife
            let water = NSColor(red: 0.55, green: 0.72, blue: 0.92, alpha: 1)
            let color = q.glyph == "♥" ? blushPink : ((q.glyph == "○" || q.glyph == "•") ? water : sparkGold)
            let edgeFade = min(1, max(0, (min(bounds.height, p.ceiling) - q.position.y) / 14))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: roundedFont(11 + 5 * (1 - k), .bold),
                .foregroundColor: color.withAlphaComponent(min(1, k * 1.4) * edgeFade)
            ]
            NSAttributedString(string: q.glyph, attributes: attrs).draw(at: q.position)
        }
    }

    private func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let f = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = f.fontDescriptor.withDesign(.rounded), let r = NSFont(descriptor: d, size: size) { return r }
        return f
    }
}

/// Renders the pet into a square PNG so the .app icon is the pet itself.
enum IconRenderer {
    /// Debug helper: a contact sheet of the important poses, so the drawing can be checked without a screen.
    static func renderPoses(to url: URL) {
        if SpriteAtlas.image != nil { renderSpritePoses(to: url); return }
        let view = PetView(frame: CGRect(origin: .zero, size: PetGeometry.viewSize))
        var poses: [(String, PetPose)] = []
        var p = PetPose(); poses.append(("standing", p))
        p = PetPose(); p.mouth = .happy; p.smile = 1; p.earPerk = 1; p.blush = 1; p.eyeStyle = .happy; p.tailPhase = 1.2; poses.append(("happy", p))
        p = PetPose(); p.mouth = .chomp; p.chomp = 1; p.eyeStyle = .happy; p.earPerk = 1; poses.append(("chomp", p))
        p = PetPose(); p.flop = 1; p.squashX = 1.32; p.squashY = 0.62; p.eyeStyle = .closed; p.eyeOpen = 0; p.mouth = .sleepy; p.zzz = 1; p.earPerk = 0.05; p.shadow = 1; poses.append(("nap", p))
        p = PetPose(); p.submerged = 1; p.waterline = PetGeometry.bodyBottom + PetGeometry.submergeDepth; p.earPerk = 0.5; p.wake = 1; p.finSway = 3; p.tilt = -0.1; poses.append(("submerged", p))
        p = PetPose(); p.submerged = 1; p.waterline = PetGeometry.bodyBottom + PetGeometry.submergeDepth * PetGeometry.periscopeFraction; p.earPerk = 0.5; p.look = CGPoint(x: 0.5, y: 0.3); poses.append(("periscope", p))
        p = PetPose(); p.mouth = .surprised; p.tilt = 0.25; p.eyeOpen = 1.15; p.squashX = 0.96; p.squashY = 1.06; p.earPerk = 0.2; poses.append(("dragging", p))
        p = PetPose(); p.tilt = -0.14; p.finSway = 4; p.earPerk = 0.8; p.look = CGPoint(x: 0.7, y: -0.2); p.thought = "hm"; p.thoughtAlpha = 1; poses.append(("curious", p))
        let scale: CGFloat = 3
        let cell = PetGeometry.viewSize.width * scale
        let cols = 4, rows = 2
        let image = NSImage(size: NSSize(width: cell * CGFloat(cols), height: cell * CGFloat(rows)), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            NSColor(white: 0.93, alpha: 1).setFill(); rect.fill()
            for (i, (name, pose)) in poses.enumerated() {
                let col = i % cols, row = rows - 1 - i / cols
                let ox = CGFloat(col) * cell, oy = CGFloat(row) * cell
                ctx.saveGState()
                // "screen" area: white above the waterline, blue "water" below when submerged
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: ox + 2, y: oy + 2, width: cell - 4, height: cell - 4))
                if pose.submerged > 0 {
                    ctx.setFillColor(NSColor(red: 0.80, green: 0.88, blue: 0.96, alpha: 1).cgColor)
                    ctx.fill(CGRect(x: ox + 2, y: oy + 2, width: cell - 4, height: pose.waterline * scale))
                }
                ctx.translateBy(x: ox, y: oy)
                ctx.scaleBy(x: scale, y: scale)
                view.pose = pose
                view.draw(view.bounds)
                ctx.restoreGState()
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.darkGray]
                NSAttributedString(string: name, attributes: attrs).draw(at: CGPoint(x: ox + 12, y: oy + 10))
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    /// Contact sheet of the sprite states (one representative frame each) plus the waterline poses.
    static func renderSpritePoses(to url: URL) {
        let view = PetView(frame: CGRect(origin: .zero, size: PetGeometry.viewSize))
        var cells: [(String, PetPose, SpriteFrame?)] = []
        let base = PetPose()
        cells.append(("idle", base, SpriteFrame(row: 0, col: 0)))
        cells.append(("idle blink", base, SpriteFrame(row: 0, col: 1)))
        var p = base; p.eyeOpen = 0; p.eyeStyle = .closed
        cells.append(("awake blink", p, nil))
        p = base; p.napping = true; p.mouth = .chomp; p.flop = 0
        cells.append(("nap entry", p, nil))
        cells.append(("walk right", base, SpriteFrame(row: 1, col: 2)))
        cells.append(("walk left", base, SpriteFrame(row: 2, col: 2)))
        p = base; p.held = true; p.mouth = .surprised; p.squashX = 0.95; p.squashY = 1.07; p.tilt = -0.20
        cells.append(("held left", p, nil))
        p = base; p.held = true; p.mouth = .surprised; p.squashX = 0.95; p.squashY = 1.07; p.tilt = 0.20
        cells.append(("held right", p, nil))
        cells.append(("waving", base, SpriteFrame(row: 3, col: 1)))
        cells.append(("jumping", base, SpriteFrame(row: 4, col: 2)))
        cells.append(("gentle oops", base, SpriteFrame(row: 5, col: 1)))
        cells.append(("waiting", base, SpriteFrame(row: 6, col: 1)))
        p = base; p.thought = "hm"; p.thoughtAlpha = 1; cells.append(("idle thought signal", p, nil))
        cells.append(("laptop", base, SpriteFrame(row: 7, col: 1)))
        cells.append(("celebrate", base, SpriteFrame(row: 8, col: 2)))
        for (name, dx, dy) in [
            ("look above", CGFloat(0), CGFloat(1)),
            ("look upper right", CGFloat(1), CGFloat(1)),
            ("look right", CGFloat(1), CGFloat(0)),
            ("look lower right", CGFloat(1), CGFloat(-1)),
            ("look below", CGFloat(0), CGFloat(-1)),
            ("look lower left", CGFloat(-1), CGFloat(-1)),
            ("look left", CGFloat(-1), CGFloat(0)),
            ("look upper left", CGFloat(-1), CGFloat(1))
        ] {
            p = base; p.look = CGPoint(x: dx, y: dy)
            cells.append((name, p, nil))
        }
        p = base; p.napping = true; p.eyeStyle = .closed; p.zzz = 1; p.shadow = 1
        cells.append(("nap", p, SpriteFrame(row: 5, col: 2)))
        p = base; p.walk = 1; p.squashX = 0.75; p.squashY = 0.75; cells.append(("stroll (compact)", p, SpriteFrame(row: 1, col: 3)))
        p = base; p.napping = true; p.flop = 1; p.eyeStyle = .closed; p.zzz = 1; cells.append(("lying nap", p, SpriteFrame(row: 5, col: 2)))
        for coat in Coat.allCases {
            p = base; p.coat = coat
            cells.append((coat.title, p, SpriteFrame(row: 0, col: 0)))
        }
        let scale: CGFloat = 3
        let cell = PetGeometry.viewSize.width * scale
        let cols = 4, rows = (cells.count + cols - 1) / cols
        let image = NSImage(size: NSSize(width: cell * CGFloat(cols), height: cell * CGFloat(rows)), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            NSColor(white: 0.93, alpha: 1).setFill(); rect.fill()
            for (i, (name, pose, frame)) in cells.enumerated() {
                let col = i % cols, row = rows - 1 - i / cols
                let ox = CGFloat(col) * cell, oy = CGFloat(row) * cell
                ctx.saveGState()
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(CGRect(x: ox + 2, y: oy + 2, width: cell - 4, height: cell - 4))
                if pose.submerged > 0 {
                    ctx.setFillColor(NSColor(red: 0.80, green: 0.88, blue: 0.96, alpha: 1).cgColor)
                    ctx.fill(CGRect(x: ox + 2, y: oy + 2, width: cell - 4, height: pose.waterline * scale))
                }
                ctx.translateBy(x: ox, y: oy)
                ctx.scaleBy(x: scale, y: scale)
                view.spriteFrameOverride = frame
                view.pose = pose
                view.draw(view.bounds)
                ctx.restoreGState()
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor.darkGray]
                NSAttributedString(string: name, attributes: attrs).draw(at: CGPoint(x: ox + 12, y: oy + 10))
            }
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    static func render(to url: URL) {
        let size: CGFloat = 1024
        let view = PetView(frame: CGRect(origin: .zero, size: PetGeometry.viewSize))
        view.spriteFrameOverride = SpriteFrame(row: 3, col: 1)   // a friendly wave on the icon
        var pose = PetPose()
        pose.earPerk = 0.25
        pose.mouth = .happy
        pose.look = CGPoint(x: 0.1, y: 0.2)
        pose.blush = 0.9
        pose.tailPhase = 0.8
        view.pose = pose

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let square = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
            let path = NSBezierPath(roundedRect: square, xRadius: size * 0.185, yRadius: size * 0.185)
            let gradient = NSGradient(starting: NSColor(red: 0.62, green: 0.78, blue: 0.93, alpha: 1),
                                      ending: NSColor(red: 0.87, green: 0.94, blue: 1.00, alpha: 1))
            gradient?.draw(in: path, angle: 90)
            ctx.saveGState()
            path.addClip()
            let scale: CGFloat = SpriteAtlas.image != nil ? 5.0 : 5.6
            ctx.translateBy(x: size / 2 - PetGeometry.bodyCenter.x * scale,
                            y: size * 0.5 - PetGeometry.bodyCenter.y * scale)
            ctx.scaleBy(x: scale, y: scale)
            view.draw(view.bounds)
            ctx.restoreGState()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
