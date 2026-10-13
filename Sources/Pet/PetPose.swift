import AppKit

enum Mouth { case neutral, happy, surprised, sleepy, chomp }
enum EyeStyle { case open, happy, closed }

struct Particle {
    var position: CGPoint      // view coordinates
    var velocity: CGVector
    var life: CGFloat          // seconds remaining
    var maxLife: CGFloat
    var glyph: String
}

/// Everything the view needs to draw one frame of the pet.
struct PetPose {
    var bob: CGFloat = 0
    var squashX: CGFloat = 1
    var squashY: CGFloat = 1
    var tilt: CGFloat = 0
    var facing: CGFloat = 1          // 1 = looking right, -1 = looking left
    var eyeOpen: CGFloat = 1         // 0 closed ... 1 open
    var eyeStyle: EyeStyle = .open
    var napping: Bool = false       // explicit dog sleep pose; a blink must not turn into a nap
    var held: Bool = false          // front-facing dangling pose while the user drags Pet
    var look: CGPoint = .zero        // -1...1, already facing-adjusted
    var earPerk: CGFloat = 0.4       // 0 droopy ... 1 perked up
    var mouth: Mouth = .neutral
    var blush: CGFloat = 0.6
    var tailPhase: CGFloat = 0
    var tailWag: CGFloat = 1
    var shadow: CGFloat = 0          // ground shadow strength
    var zzz: CGFloat = 0             // sleep bubbles strength
    var time: CGFloat = 0
    var particles: [Particle] = []
    var thought: String = ""         // glyph shown in a little thought bubble
    var thoughtAlpha: CGFloat = 0
    var coat: Coat = .hojiro
    var displayScale: CGFloat = 1     // persistent user size, independent of the temporary compact stroll scale
    var submerged: CGFloat = 0       // 1 = only the fin shows above the "water" (screen edge)
    var waterline: CGFloat = -1000   // view-space y of the screen edge while submerged
    var chomp: CGFloat = 0           // 0 closed-ish ... 1 wide open snap
    var flop: CGFloat = 0            // 1 = lying flat (nap pose)
    var finSway: CGFloat = 0         // sideways lean of the dorsal fin (tail-beat)
    var wake: CGFloat = 0            // cruise speed 0...1
    var smile: CGFloat = 0           // eases the mouth between neutral and happy
    var walk: CGFloat = 0            // -1 walking left, +1 walking right, 0 standing (picks the running rows)
    var listening: CGFloat = 0       // 1 while the user is speaking into the mic
    var music: CGFloat = 0           // 1 while music is playing (draw the little spinning disc)
    var discAngle: CGFloat = 0       // radians, keeps turning while music plays
    var ceiling: CGFloat = 10000     // view-space y of the top of the screen (nothing drawn above it)

    /// The top of the body as drawn (squash and flop change it).
    var bodyTopNow: CGFloat { PetGeometry.bodyBottom + bob + 2 * PetGeometry.bodyHalfHeight * squashY }
}

/// A colour for one region of the sprite: absolute hue in degrees, multipliers on the original saturation and value.
struct SpriteTone { var hue: CGFloat; var sat: CGFloat; var val: CGFloat }

/// Skins the user can pick. `body`/`shade` colour effects; `spriteTone` recolours only dog fur.
/// nil keeps the source art's original blue.
enum Coat: String, CaseIterable, Hashable {
    case sand, hojiro, deep, sakura, mint, charcoal
    var title: String {
        switch self {
        case .sand: return "Sand"; case .hojiro: return "Original blue"; case .deep: return "Deep navy"
        case .sakura: return "Coral"; case .mint: return "Forest green"; case .charcoal: return "Charcoal"
        }
    }
    var spriteTone: SpriteTone? {
        switch self {
        case .hojiro:   return nil
        case .sand:     return SpriteTone(hue: 38, sat: 0.5, val: 1.0)
        case .deep:     return SpriteTone(hue: 225, sat: 1.1, val: 0.62)
        case .sakura:   return SpriteTone(hue: 12, sat: 0.85, val: 1.0)
        case .mint:     return SpriteTone(hue: 145, sat: 0.9, val: 0.72)
        case .charcoal: return SpriteTone(hue: 220, sat: 0.10, val: 0.55)
        }
    }
    var body: NSColor {
        switch self {
        case .sand:     return NSColor(red: 0.93, green: 0.80, blue: 0.58, alpha: 1)
        case .hojiro:   return NSColor(red: 0.42, green: 0.56, blue: 0.76, alpha: 1)
        case .deep:     return NSColor(red: 0.20, green: 0.30, blue: 0.62, alpha: 1)
        case .sakura:   return NSColor(red: 0.96, green: 0.55, blue: 0.48, alpha: 1)
        case .mint:     return NSColor(red: 0.30, green: 0.62, blue: 0.42, alpha: 1)
        case .charcoal: return NSColor(red: 0.43, green: 0.45, blue: 0.51, alpha: 1)
        }
    }
    var shade: NSColor {   // belly (vector fallback) / light tint
        switch self {
        case .sand:     return NSColor(red: 0.99, green: 0.94, blue: 0.85, alpha: 1)
        case .hojiro:   return NSColor(red: 0.97, green: 0.95, blue: 0.88, alpha: 1)
        case .deep:     return NSColor(red: 0.89, green: 0.93, blue: 0.97, alpha: 1)
        case .sakura:   return NSColor(red: 0.99, green: 0.90, blue: 0.93, alpha: 1)
        case .mint:     return NSColor(red: 0.89, green: 0.96, blue: 0.94, alpha: 1)
        case .charcoal: return NSColor(red: 0.85, green: 0.86, blue: 0.89, alpha: 1)
        }
    }
    var outline: NSColor { NSColor(red: 0.13, green: 0.19, blue: 0.34, alpha: 1) }
    var features: NSColor { NSColor(red: 0.11, green: 0.15, blue: 0.27, alpha: 1) }
}

enum PetGeometry {
    static let viewSize = CGSize(width: 170, height: 170)
    /// Dog sprites are up to 170 px wide and tall. Idle stands about 108 pt tall.
    static let spriteScale: CGFloat = 0.82
    static let bodyCenter = CGPoint(x: 85, y: 74)   // unchanged: the controller's grab/dive thresholds hang off this
    static let bodyHalfWidth: CGFloat = 70
    static let bodyHalfHeight: CGFloat = 46          // bodyBottom 28 … bodyTop 120
    /// Half the drawn character's maximum height.
    static var characterHalfHeight: CGFloat { (bodyHalfHeight * 2 + earHeight) / 2 }
    static let earHeight: CGFloat = 47               // tallest pose reaches about 167 pt
    /// Area (view coords) that counts as "the pet" for hover and clicks.
    static let hitRect = CGRect(x: 12, y: 24, width: 146, height: 146)
    /// How far the body sinks below the screen edge when only the ears peek out.
    static let submergeDepth: CGFloat = 108
    /// Legacy edge-peek fraction, retained for the controller's position math.
    static let periscopeFraction: CGFloat = 76.0 / 108.0

    /// Origin of the sprite cell in view coords (before bob/squash), so the character's feet sit on bodyBottom.
    static var spriteCellOrigin: CGPoint {
        CGPoint(x: bodyCenter.x - 96 * spriteScale, y: bodyBottom - SpriteAtlas.feetOffset * spriteScale)
    }

    /// The canonical body silhouette in body-local coords (origin at bodyCenter, y up, face toward +x).
    /// Compact egg: round head on top, subtle two-lobed base. Shared by drawing and hit-testing.
    static func bodyPath() -> CGPath {
        // Taller than wide (72 x 92): round head, sides taper to two soft base lobes with a small dip between.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 46))
        path.addCurve(to: CGPoint(x: 37, y: 12), control1: CGPoint(x: 22, y: 46), control2: CGPoint(x: 37, y: 35))
        path.addCurve(to: CGPoint(x: 15, y: -46), control1: CGPoint(x: 37, y: -10), control2: CGPoint(x: 33, y: -46))
        path.addCurve(to: CGPoint(x: 0, y: -40.5), control1: CGPoint(x: 8, y: -46), control2: CGPoint(x: 3, y: -41.5))
        path.addCurve(to: CGPoint(x: -15, y: -46), control1: CGPoint(x: -3, y: -41.5), control2: CGPoint(x: -8, y: -46))
        path.addCurve(to: CGPoint(x: -37, y: 12), control1: CGPoint(x: -33, y: -46), control2: CGPoint(x: -37, y: -10))
        path.addCurve(to: CGPoint(x: 0, y: 46), control1: CGPoint(x: -37, y: 35), control2: CGPoint(x: -22, y: 46))
        path.closeSubpath()
        return path
    }

    /// The shark's silhouette (body + fin + flippers + tail) in view coords, used for precise hover/click testing
    /// so empty pixels around it stay click-through.
    static func hitPath(bob: CGFloat, facing: CGFloat, squashX: CGFloat = 1, squashY: CGFloat = 1, napping: Bool = false) -> CGPath {
        let path = CGMutablePath()
        let t = CGAffineTransform(translationX: bodyCenter.x, y: bodyBottom + bob)
            .scaledBy(x: facing * squashX, y: squashY)
            .translatedBy(x: 0, y: bodyHalfHeight)
        if SpriteAtlas.image != nil {
            let w = bodyHalfWidth, h = bodyHalfHeight
            if napping {
                path.addPath(CGPath(roundedRect: CGRect(x: -68, y: -h, width: 136, height: 85), cornerWidth: 22, cornerHeight: 22, transform: nil), transform: t)
                return path
            }
            // the whole dog: paws at bodyBottom, ears below earTop
            path.addPath(CGPath(roundedRect: CGRect(x: -w, y: -h, width: 2 * w, height: 2 * h + earHeight), cornerWidth: 34, cornerHeight: 34, transform: nil), transform: t)
            return path
        }
        path.addPath(bodyPath(), transform: t)
        let fin = CGMutablePath()   // dorsal fin, leaning back toward the tail
        fin.move(to: CGPoint(x: 10, y: 30)); fin.addLine(to: CGPoint(x: -16, y: 70)); fin.addLine(to: CGPoint(x: -30, y: 30)); fin.closeSubpath()
        path.addPath(fin, transform: t)
        path.addPath(CGPath(ellipseIn: CGRect(x: 24, y: -36, width: 22, height: 34), transform: nil), transform: t)   // near flipper
        path.addPath(CGPath(ellipseIn: CGRect(x: -46, y: -26, width: 30, height: 34), transform: nil), transform: t)  // far flipper
        path.addPath(CGPath(ellipseIn: CGRect(x: -62, y: -36, width: 34, height: 44), transform: nil), transform: t)  // tail
        return path
    }

    static var bodyBottom: CGFloat { bodyCenter.y - bodyHalfHeight }   // 28
    static var bodyTop: CGFloat { bodyCenter.y + bodyHalfHeight }      // 120
    static var earTop: CGFloat { bodyTop + earHeight }                 // 167
}

@inline(__always)
func approach(_ a: CGFloat, _ b: CGFloat, rate: CGFloat, dt: CGFloat) -> CGFloat {
    a + (b - a) * min(1, rate * dt)
}
