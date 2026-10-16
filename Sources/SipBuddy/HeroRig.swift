import CoreGraphics
import Foundation

// MARK: - Skeleton

/// Heroic proportions (head ≈ 1/5 of height). Units: feet on y = 0, about 250 tall, facing right (3/4 view).
enum Rig {
    static let height: CGFloat = 250
    static let shoulder = CGPoint(x: 46, y: 183)
    static let upperArm: CGFloat = 40
    static let foreArm: CGFloat = 37
    static let hip = CGPoint(x: 15, y: 114)
    static let thigh: CGFloat = 54
    static let shin: CGFloat = 50
    static let head = CGPoint(x: 2, y: 224)
    static let mouth = CGPoint(x: 6, y: 212)

    /// Shoulder and elbow angles that put the right fist at `target` (two-bone IK, elbow pointing out).
    /// Arm convention: 0 = hanging down, + = rotated outward; elbow + = forearm folds inward/up.
    static func reachRight(_ target: CGPoint, drop: CGFloat = 0) -> (shoulder: CGFloat, elbow: CGFloat) {
        let s = CGPoint(x: shoulder.x, y: shoulder.y - drop)
        let v = CGPoint(x: target.x - s.x, y: target.y - s.y)
        let d = min(upperArm + foreArm - 0.5, max(10, hypot(v.x, v.y)))
        let phi = atan2(v.x, -v.y)
        let alpha = acos(min(1, (upperArm * upperArm + d * d - foreArm * foreArm) / (2 * upperArm * d)))
        let inner = acos(min(1, (upperArm * upperArm + foreArm * foreArm - d * d) / (2 * upperArm * foreArm)))
        return (phi + alpha, .pi - inner)
    }
}

// MARK: - Pose

/// Every joint and expression of the puppet. All values are continuous so poses can blend.
struct Pose {
    var lift: CGFloat = 0          // whole body off the ground (jumps, hops)
    var squash: CGFloat = 1        // < 1 squashed, > 1 stretched (kept subtle for heroic bodies)
    var lean: CGFloat = 0          // body rotation around the feet
    var headTilt: CGFloat = 0
    var armL: CGFloat = 0.12       // shoulder: 0 = hanging, + = raised outward
    var armR: CGFloat = 0.22
    var elbowL: CGFloat = 0.2      // + = forearm folds inward/up
    var elbowR: CGFloat = 0.9
    var legL: CGFloat = 0.04       // hip: + = outward
    var legR: CGFloat = 0.04
    var kneeL: CGFloat = 0         // + = bent (foot lifts)
    var kneeR: CGFloat = 0
    var sit: CGFloat = 0           // 0 standing … 1 sitting
    var eyesOpen: CGFloat = 1
    var lookX: CGFloat = 0.3       // −1 … 1, + = toward facing direction
    var lookY: CGFloat = 0
    var smile: CGFloat = 0.35      // −1 frown … 1 big smile
    var mouthOpen: CGFloat = 0
    var brow: CGFloat = 0          // −1 determined … 1 raised
    var capeFlare: CGFloat = 0.2
    var capeTrail: CGFloat = 0     // cape pushed behind (walking)
    var cupTilt: CGFloat = 0
    // Not sprung: continuously advancing phase.
    var capeWave: CGFloat = 0

    static let sprung: [(WritableKeyPath<Pose, CGFloat>, stiffness: CGFloat, damping: CGFloat)] = [
        (\.lift, 220, 0.75), (\.squash, 320, 0.4), (\.lean, 140, 0.6), (\.headTilt, 120, 0.55),
        (\.armL, 170, 0.62), (\.armR, 170, 0.66), (\.elbowL, 170, 0.66), (\.elbowR, 170, 0.7),
        (\.legL, 200, 0.75), (\.legR, 200, 0.75), (\.kneeL, 240, 0.8), (\.kneeR, 240, 0.8),
        (\.sit, 60, 0.9), (\.eyesOpen, 1400, 1), (\.lookX, 50, 0.9), (\.lookY, 50, 0.9),
        (\.smile, 90, 0.9), (\.mouthOpen, 160, 0.8), (\.brow, 90, 0.9), (\.capeFlare, 60, 0.45),
        (\.capeTrail, 50, 0.5), (\.cupTilt, 120, 0.7),
    ]
}

/// Springs the displayed pose toward a target pose, which is what makes motion feel weighty and alive.
struct PoseAnimator {
    private(set) var pose = Pose()
    private var velocity = PoseAnimator.zero

    private static var zero: Pose {
        var p = Pose()
        for (kp, _, _) in Pose.sprung { p[keyPath: kp] = 0 }
        return p
    }

    mutating func update(toward target: Pose, dt: CGFloat) {
        let steps = max(1, Int(ceil(dt / (1 / 120))))
        let h = dt / CGFloat(steps)
        for _ in 0..<steps {
            for (kp, k, zeta) in Pose.sprung {
                let x = pose[keyPath: kp], v = velocity[keyPath: kp]
                let a = k * (target[keyPath: kp] - x) - 2 * zeta * sqrt(k) * v
                velocity[keyPath: kp] = v + a * h
                pose[keyPath: kp] = x + velocity[keyPath: kp] * h
            }
        }
        pose.capeWave = target.capeWave
    }

    /// Adds a sudden velocity, e.g. a squash on landing.
    mutating func kick(_ kp: WritableKeyPath<Pose, CGFloat>, _ amount: CGFloat) {
        velocity[keyPath: kp] += amount
    }
}

// MARK: - Pose library

/// Target poses for each behavior. Pure functions of time, shared by the live buddy and previews.
enum PoseLibrary {
    static func blinking(_ t: Double) -> Bool {
        let cycle = t.truncatingRemainder(dividingBy: 4.3)
        return cycle < 0.13 || (cycle > 2.1 && cycle < 2.2 && Int(t / 4.3) % 3 == 0)
    }

    static func idle(_ t: Double) -> Pose {
        var p = Pose()
        let breath = CGFloat(sin(t * 2.0))
        p.squash = 1 + 0.012 * breath
        p.lean = 0.015 * CGFloat(sin(t * 0.8))
        p.headTilt = 0.04 * CGFloat(sin(t * 0.65))
        p.armL = 0.12 + 0.02 * breath
        p.armR = 0.2 + 0.02 * breath
        p.eyesOpen = blinking(t) ? 0 : 1
        p.capeWave = CGFloat(t * 1.6)
        p.capeFlare = 0.15
        return p
    }

    static func walk(phase: Double, _ t: Double) -> Pose {
        var p = idle(t)
        let s = CGFloat(sin(phase))
        p.kneeL = max(0, s) * 0.9
        p.kneeR = max(0, -s) * 0.9
        p.legL = 0.04 + 0.08 * s
        p.legR = 0.04 - 0.08 * s
        p.lean = 0.05
        p.lift = abs(s) * 4
        p.armL = 0.15 - 0.22 * s
        p.elbowL = 0.35 + 0.2 * max(0, s)
        p.armR = 0.22 + 0.12 * s
        p.headTilt = -0.03 * s
        p.capeTrail = 1
        p.capeFlare = 0.6
        p.capeWave = CGFloat(t * 6)
        p.smile = 0.4
        return p
    }

    static func remind(_ t: Double) -> Pose {
        var p = idle(t)
        let c = t.truncatingRemainder(dividingBy: 1.3)
        p.lift = c < 0.4 ? CGFloat(sin(c / 0.4 * .pi)) * 30 : 0
        p.kneeL = c < 0.4 ? 0.5 : 0
        p.kneeR = c < 0.4 ? 0.5 : 0
        p.armL = 2.55
        p.elbowL = 0.35 + 0.45 * CGFloat(sin(t * 10))   // waving
        p.armR = 0.9
        p.elbowR = 1.3                                  // showing the cup
        p.brow = 0.6
        p.smile = 0.5
        p.mouthOpen = 0.4
        p.capeFlare = 0.7
        p.capeWave = CGFloat(t * 5)
        return p
    }

    static let drinkDuration = 2.4

    static func drink(_ local: Double, _ t: Double) -> Pose {
        var p = idle(t)
        let raise = smooth(local / 0.45)
        let lower = smooth((local - 1.8) / 0.4)
        let up = CGFloat(raise * (1 - lower))
        let toMouth = Rig.reachRight(CGPoint(x: Rig.mouth.x + 6, y: Rig.mouth.y - 14))
        p.armR = 0.2 + (toMouth.shoulder - 0.2) * up
        p.elbowR = 0.9 + (toMouth.elbow - 0.9) * up
        p.cupTilt = up * 0.9
        p.headTilt = -0.2 * up
        p.eyesOpen = up > 0.6 ? 0 : 1
        p.smile = up > 0.6 ? 0.2 : 0.5
        if local > 0.5 && local < 1.8 {
            p.squash = 1 + 0.012 * CGFloat(sin(local * 14))   // gulp
        }
        if local > 1.8 {
            p.mouthOpen = 0.35
            p.smile = 0.9
            p.eyesOpen = 0
        }
        return p
    }

    static let cheerDuration = 1.4

    static func cheer(_ local: Double, _ t: Double) -> Pose {
        var p = idle(t)
        p.smile = 0.9
        p.eyesOpen = 0
        p.mouthOpen = 0.5
        p.capeFlare = 1
        p.capeWave = CGFloat(t * 7)
        if local < 0.25 {                       // anticipation crouch
            p.squash = 0.94
            p.kneeL = 0.5; p.kneeR = 0.5
            p.armL = 0.5; p.armR = 0.6
            p.elbowL = 0.8; p.elbowR = 1.0
        } else if local < 0.85 {                // jump, fists up
            let j = (local - 0.25) / 0.6
            p.lift = CGFloat(sin(j * .pi)) * 60
            p.squash = 1.03
            p.armL = 2.45 + 0.1 * CGFloat(sin(t * 16))
            p.armR = 2.45 + 0.1 * CGFloat(sin(t * 16 + 1))
            p.elbowL = 0.15; p.elbowR = 0.15
            p.kneeL = 0.7; p.kneeR = 0.3
        } else {                                // landed, victory pose
            p.armL = 2.3; p.armR = 2.3
            p.elbowL = 0.3; p.elbowR = 0.3
        }
        return p
    }

    static func sleep(_ t: Double) -> Pose {
        var p = Pose()
        p.sit = 1
        p.eyesOpen = 0
        p.smile = 0.15
        p.headTilt = 0.25 + 0.04 * CGFloat(sin(t * 1.3))
        p.squash = 1 + 0.012 * CGFloat(sin(t * 1.3))
        p.armL = 0.45; p.armR = 0.5
        p.elbowL = 0.5; p.elbowR = 0.6
        p.legL = 0.55; p.legR = 0.55
        p.capeWave = CGFloat(t * 0.8)
        return p
    }

    static func dangle(_ t: Double, swing: CGFloat) -> Pose {
        var p = Pose()
        p.armL = 2.3 + 0.3 * CGFloat(sin(t * 13))
        p.armR = 2.3 + 0.3 * CGFloat(sin(t * 13 + 2))
        p.elbowL = 0.4 + 0.3 * CGFloat(sin(t * 9))
        p.elbowR = 0.4 + 0.3 * CGFloat(sin(t * 9 + 1))
        p.legL = 0.08 + 0.12 * CGFloat(sin(t * 8)) + swing
        p.legR = 0.08 - 0.12 * CGFloat(sin(t * 8)) - swing
        p.kneeL = 0.3 + 0.3 * CGFloat(sin(t * 8))
        p.kneeR = 0.3 - 0.3 * CGFloat(sin(t * 8))
        p.lean = -swing * 0.6
        p.eyesOpen = 1.1
        p.brow = 1
        p.smile = -0.2
        p.mouthOpen = 0.6
        p.capeFlare = 1
        p.capeWave = CGFloat(t * 9)
        return p
    }

    static func falling(_ t: Double) -> Pose {
        var p = dangle(t, swing: 0)
        p.legL = 0.05; p.legR = 0.05
        p.kneeL = 0.2; p.kneeR = 0.2
        return p
    }

    static func preview(_ anim: Anim, _ t: Double) -> Pose {
        switch anim {
        case .walk: walk(phase: t * 7.5, t)
        case .idle: idle(t)
        case .drink: drink(t.truncatingRemainder(dividingBy: drinkDuration + 0.6), t)
        case .cheer: cheer(t.truncatingRemainder(dividingBy: cheerDuration + 0.5), t)
        case .sleep: sleep(t)
        }
    }

    private static func smooth(_ x: Double) -> Double {
        let c = min(1, max(0, x))
        return c * c * (3 - 2 * c)
    }
}

// MARK: - Renderer

/// Draws a HeroLook as a stylized action figure: satin suits, shaded skin, polished metal armor.
enum HeroRenderer {
    static let height = Rig.height
    static let aspect: CGFloat = 0.62

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static var satinGradients: [RGB: CGGradient] = [:]
    private static var metalGradients: [RGB: CGGradient] = [:]
    /// While drawing armor, fills use the polished-metal material instead of satin.
    private static var metal = false
    /// Body proportions: build scales everything; the feminine figure narrows the shoulders and waist,
    /// widens the hips and slims the limbs.
    struct Body {
        var bw: CGFloat          // overall build
        var shoulder: CGFloat    // shoulder & chest width
        var waist: CGFloat
        var hip: CGFloat
        var arm: CGFloat         // arm & hand thickness
        var leg: CGFloat         // leg & boot thickness
        var feminine: Bool

        init(_ look: HeroLook) {
            bw = look.build == .big ? 1.25 : 1
            feminine = look.isFeminine
            shoulder = feminine ? 0.84 : 1
            waist = feminine ? 0.8 : 1
            hip = feminine ? 1.14 : 1
            arm = feminine ? 0.74 : 1
            leg = feminine ? 0.86 : 1
        }

        var shoulderX: CGFloat { Rig.shoulder.x * bw * shoulder }
    }

    private static let glow = RGB(0x9FF3FF)
    private static let ink = RGB(0x1C1820)

    static func draw(_ ctx: CGContext, _ look: HeroLook, _ pose: Pose) {
        var p = pose
        switch look.attitude ?? .cheerful {
        case .stoic: p.brow -= 0.7; p.smile = p.smile * 0.25 - 0.05
        case .fierce: p.brow -= 1.1; p.smile = p.smile * 0.4 - 0.15
        case .cheerful: break
        }
        ctx.saveGState()
        defer { ctx.restoreGState(); metal = false }
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)

        // Ground shadow stays on the floor while the body jumps.
        let shadowScale = max(0.35, 1 - p.lift / 160)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.2 * shadowScale))
        ctx.fillEllipse(in: CGRect(x: -40 * shadowScale + 4, y: -5, width: 80 * shadowScale, height: 10))

        // Body transform: lift, lean around the feet, a little squash & stretch.
        ctx.translateBy(x: 0, y: p.lift)
        ctx.rotate(by: -p.lean)
        let sq = 1 + (p.squash - 1) * 0.5
        ctx.scaleBy(x: 1 / sqrt(max(0.5, sq)), y: sq)

        let outfit = look.outfit ?? .bodysuit
        let body = Body(look)
        let bw = body.bw
        let drop = 82 * p.sit
        let hipY = Rig.hip.y - drop
        let coversHead = Self.coversHead(look.mask)
        metal = outfit == .armor

        // Back layers.
        if let cape = look.cape { drawCape(ctx, cape, p, drop: drop) }
        if !coversHead || (look.hairStyle == .ponytail && (look.mask == .fullface || look.mask == .cowl)) {
            drawBackHair(ctx, look, p, drop: drop)
        }

        // Legs, then pelvis.
        for left in [true, false] { drawLeg(ctx, look, p, left: left, hipY: hipY, body: body) }
        let hw = bw * body.hip
        let pelvis = roundedPoly([CGPoint(x: -29 * hw, y: hipY - 12), CGPoint(x: 29 * hw, y: hipY - 12),
                                  CGPoint(x: 30 * hw, y: hipY + 14), CGPoint(x: -30 * hw, y: hipY + 14)], r: 9)
        fill(ctx, pelvis, look.pants)

        // Torso: broad chest tapering to the waist (an hourglass for the feminine figure).
        let top = 198 - drop
        let torsoColor = outfit == .bare ? look.skin : look.suit
        let sw = bw * body.shoulder, ww = bw * body.waist
        let torso = roundedPoly([
            CGPoint(x: -27 * hw, y: hipY + 6), CGPoint(x: 27 * hw, y: hipY + 6),
            CGPoint(x: 31 * ww, y: hipY + 30), CGPoint(x: 46 * sw, y: top - 22), CGPoint(x: 54 * sw, y: top - 8), CGPoint(x: 30 * sw, y: top + 2),
            CGPoint(x: -30 * sw, y: top + 2), CGPoint(x: -54 * sw, y: top - 8), CGPoint(x: -46 * sw, y: top - 22), CGPoint(x: -31 * ww, y: hipY + 30),
        ], r: 10)
        fill(ctx, torso, torsoColor)
        switch outfit {
        case .bodysuit: drawSuitLines(ctx, look, top: top, hipY: hipY, body: body)
        case .tux: drawTux(ctx, look, top: top, hipY: hipY)
        case .bare: drawMuscles(ctx, look, top: top, hipY: hipY, body: body)
        case .armor: drawArmorChest(ctx, look, top: top, hipY: hipY, body: body)
        }
        if look.belt && outfit != .armor {
            fill(ctx, CGPath(roundedRect: CGRect(x: -26 * hw, y: hipY + 4, width: 52 * hw, height: 9), cornerWidth: 3, cornerHeight: 3, transform: nil), look.accent, outline: 1.2)
            fill(ctx, CGPath(roundedRect: CGRect(x: -6, y: hipY + 2.5, width: 12, height: 12), cornerWidth: 3, cornerHeight: 3, transform: nil), look.accent.scaled(1.15), outline: 1.2)
        }
        if look.emblem == .core && outfit != .armor {
            drawCore(ctx, look.emblemColor, at: CGPoint(x: 0, y: top - 26), r: 7)
        } else if look.emblem != .none && look.emblem != .core && outfit != .tux {
            var t = CGAffineTransform(translationX: 0, y: top - 28)
            if let e = emblem(look.emblem, size: look.emblem == .spider ? 15 : 10).copy(using: &t) { fill(ctx, e, look.emblemColor, outline: 1.4) }
        }

        // Neck.
        let neckColor = coversHead && look.mask != .cowl ? look.maskColor : look.skin
        let neckW: CGFloat = body.feminine ? 17 : 22
        fill(ctx, CGPath(roundedRect: CGRect(x: 1 - neckW / 2, y: top - 4, width: neckW, height: 18), cornerWidth: 7, cornerHeight: 7, transform: nil), neckColor, outline: 1.2)
        if outfit == .tux {
            fill(ctx, CGPath(roundedRect: CGRect(x: 1 - neckW / 2, y: top - 2, width: neckW, height: 7), cornerWidth: 3, cornerHeight: 3, transform: nil), RGB(0xF4F4F4), outline: 1)
        }

        // Arms (a hand raised to the mouth is drawn over the face).
        let crossing = p.elbowR > 1.9 && p.armR > 1.0
        drawArm(ctx, look, p, left: true, drop: drop, body: body)
        if !crossing { drawArm(ctx, look, p, left: false, drop: drop, body: body) }
        if outfit == .armor {
            for sign: CGFloat in [-1, 1] {
                let pw = 36 * body.arm
                let pad = CGPath(ellipseIn: CGRect(x: sign * body.shoulderX - pw / 2, y: Rig.shoulder.y - drop - 10, width: pw, height: 26 * body.arm), transform: nil)
                fill(ctx, pad, look.suit, outline: 1.6)
            }
        }

        // Head.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: top + 4)
        ctx.rotate(by: -p.headTilt)
        ctx.translateBy(x: 0, y: -(198 + 4))
        drawHead(ctx, look, p)
        ctx.restoreGState()

        if crossing { drawArm(ctx, look, p, left: false, drop: drop, body: body) }
        if p.sit > 0.5 { drawCup(ctx, look.cup, at: CGPoint(x: 52, y: 0), tilt: 0) }
    }

    // MARK: Limbs

    /// A muscular limb segment: `w0` at the joint, swelling to `wMid`, tapering to `w1`, with rounded ends.
    private static func segment(_ length: CGFloat, _ w0: CGFloat, _ w1: CGFloat, bulge wMid: CGFloat? = nil) -> CGPath {
        let mid = (wMid ?? (w0 + w1) / 2 * 1.12) / 2
        let p = CGMutablePath()
        p.move(to: CGPoint(x: -w0 / 2, y: 0))
        p.addCurve(to: CGPoint(x: -w1 / 2, y: -length),
                   control1: CGPoint(x: -mid * 1.12, y: -length * 0.25), control2: CGPoint(x: -mid, y: -length * 0.7))
        p.addArc(center: CGPoint(x: 0, y: -length), radius: w1 / 2, startAngle: .pi, endAngle: 0, clockwise: false)
        p.addCurve(to: CGPoint(x: w0 / 2, y: 0),
                   control1: CGPoint(x: mid, y: -length * 0.7), control2: CGPoint(x: mid * 1.12, y: -length * 0.25))
        p.addArc(center: .zero, radius: w0 / 2, startAngle: 0, endAngle: .pi, clockwise: false)
        p.closeSubpath()
        return p
    }

    private static func drawLeg(_ ctx: CGContext, _ look: HeroLook, _ p: Pose, left: Bool, hipY: CGFloat, body: Body) {
        let bw = body.bw * body.leg
        let sign: CGFloat = left ? -1 : 1
        let hipAngle = left ? p.legL : p.legR
        let knee = max(0, left ? p.kneeL : p.kneeR)
        let armor = look.outfit == .armor
        let legColor = look.outfit == .bare ? look.skin : look.pants
        // Sitting folds the thigh toward the viewer, so it foreshortens.
        let thighLen = Rig.thigh * (1 - 0.72 * p.sit)
        ctx.saveGState()
        ctx.translateBy(x: sign * Rig.hip.x * body.bw * body.hip, y: hipY)
        ctx.rotate(by: sign * hipAngle)
        // The feminine thigh is full at the hip and tapers to a slim knee.
        fill(ctx, body.feminine ? segment(thighLen, 31 * bw, 17 * bw, bulge: 31 * bw)
                                : segment(thighLen, 28 * bw, 19 * bw, bulge: 31 * bw), legColor)
        ctx.translateBy(x: 0, y: -thighLen)
        // Knee: the shin swings back and up when bent.
        ctx.rotate(by: -sign * hipAngle + knee * 0.55)
        let shinLen = Rig.shin * (1 - 0.18 * knee)
        fill(ctx, body.feminine ? segment(shinLen, 17 * bw, 11 * bw, bulge: 20 * bw)
                                : segment(shinLen, 19 * bw, 13 * bw, bulge: 23 * bw), armor ? look.boots : legColor.scaled(0.97))
        if armor {
            fill(ctx, CGPath(ellipseIn: CGRect(x: -8, y: -6, width: 16, height: 12), transform: nil), look.boots.scaled(1.08), outline: 1.4)
        }
        ctx.translateBy(x: 0, y: -shinLen)
        ctx.rotate(by: -knee * 0.55)
        if armor && p.lift > 16 {
            // Boot thrusters fire while airborne.
            let flame = min(50, 12 + p.lift * 0.6)
            ctx.saveGState()
            ctx.translateBy(x: 4, y: -8)
            ctx.scaleBy(x: 0.4, y: 1)
            glowSpot(ctx, at: CGPoint(x: 0, y: -flame * 0.35), radius: flame)
            ctx.restoreGState()
        }
        let boot = roundedPoly([CGPoint(x: -9 * bw, y: 14), CGPoint(x: 9 * bw, y: 14), CGPoint(x: 11 * bw, y: 2),
                                CGPoint(x: 25 * bw, y: -1), CGPoint(x: 27 * bw, y: -7), CGPoint(x: -11 * bw, y: -7)], r: 4)
        fill(ctx, boot, look.boots, outline: 1.6)
        ctx.restoreGState()
    }

    private static func drawArm(_ ctx: CGContext, _ look: HeroLook, _ p: Pose, left: Bool, drop: CGFloat, body: Body) {
        let bw = body.bw * body.arm
        let sign: CGFloat = left ? -1 : 1
        let shoulder = left ? p.armL : p.armR
        let elbow = left ? p.elbowL : p.elbowR
        let sleeve = look.outfit == .bare ? look.skin : look.suit
        let armor = look.outfit == .armor
        ctx.saveGState()
        ctx.translateBy(x: sign * body.shoulderX, y: Rig.shoulder.y - drop)
        ctx.rotate(by: sign * shoulder)
        // Deltoid + upper arm.
        fill(ctx, segment(Rig.upperArm, 25 * bw, 17 * bw, bulge: 26 * bw), sleeve.scaled(0.96))
        if armor {
            fill(ctx, CGPath(roundedRect: CGRect(x: -8 * bw, y: -20, width: 16 * bw, height: 9), cornerWidth: 3, cornerHeight: 3, transform: nil), look.accent, outline: 1.2)
        }
        // Forearm.
        ctx.translateBy(x: 0, y: -Rig.upperArm)
        ctx.rotate(by: -sign * elbow)
        let forearmColor = look.outfit == .tux ? look.suit.scaled(0.92) : sleeve
        fill(ctx, segment(Rig.foreArm, 18 * bw, 13 * bw, bulge: 21 * bw), forearmColor)
        if look.outfit == .tux {
            fill(ctx, CGPath(roundedRect: CGRect(x: -6.5, y: -Rig.foreArm - 2, width: 13, height: 6), cornerWidth: 2, cornerHeight: 2, transform: nil), RGB(0xF4F4F4), outline: 1)
        }
        // Fist.
        ctx.translateBy(x: 0, y: -Rig.foreArm - 6)
        let worldAngle = shoulder - elbow
        if armor && worldAngle > 1.4 {
            glowSpot(ctx, at: CGPoint(x: 0, y: -6), radius: 20, alpha: 0.9)   // repulsor
        }
        let handColor = look.outfit == .tux || look.outfit == .bare ? look.skin : look.gloves
        fill(ctx, CGPath(roundedRect: CGRect(x: -9.5 * bw, y: -11 * bw, width: 19 * bw, height: 19 * bw), cornerWidth: 7, cornerHeight: 7, transform: nil), handColor, outline: 1.4)
        line(ctx, [CGPoint(x: -6 * bw, y: -1), CGPoint(x: 6 * bw, y: -1)], handColor.scaled(0.45).cg(0.5), width: 1)
        if !left && p.sit < 0.5 {
            // Keep the cup upright in the hand, then tilt it toward the mouth.
            ctx.rotate(by: -sign * worldAngle)
            drawCup(ctx, look.cup, at: CGPoint(x: 0, y: -2), tilt: p.cupTilt)
        }
        ctx.restoreGState()
    }

    private static func drawCup(_ ctx: CGContext, _ color: RGB, at point: CGPoint, tilt: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.rotate(by: tilt)
        let body = CGMutablePath()
        body.move(to: CGPoint(x: -7.5, y: 20))
        body.addLine(to: CGPoint(x: 7.5, y: 20))
        body.addLine(to: CGPoint(x: 5.5, y: -1))
        body.addLine(to: CGPoint(x: -5.5, y: -1))
        body.closeSubpath()
        fill(ctx, body, color, outline: 1.3)
        fill(ctx, CGPath(ellipseIn: CGRect(x: -6.5, y: 16.5, width: 13, height: 5), transform: nil), RGB(0xA8E1FF), outline: 1)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.5))
        ctx.fill(CGRect(x: -4.5, y: 2, width: 2, height: 13))
        ctx.restoreGState()
    }

    private static func drawCape(_ ctx: CGContext, _ color: RGB, _ p: Pose, drop: CGFloat) {
        let top = 196 - drop
        let bottom: CGFloat = 8 + 20 * p.sit
        let spread = 46 + 32 * p.capeFlare
        let trail = -30 * p.capeTrail
        let w = p.capeWave
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -36, y: top))
        path.addCurve(to: CGPoint(x: -spread + trail + 4 * sin(w), y: bottom + 10),
                      control1: CGPoint(x: -50, y: top - 60), control2: CGPoint(x: -spread + trail, y: bottom + 60))
        let points = 5
        for i in 1...points {
            let f = CGFloat(i) / CGFloat(points)
            let x = -spread + 2 * spread * f + trail * (1 - f * 0.5) + 4 * sin(w + CGFloat(i))
            path.addQuadCurve(to: CGPoint(x: x, y: bottom + 10 + 3 * sin(w * 1.3 + CGFloat(i))),
                              control: CGPoint(x: x - spread / CGFloat(points), y: bottom - 4))
        }
        path.addCurve(to: CGPoint(x: 36, y: top),
                      control1: CGPoint(x: spread + trail * 0.5, y: bottom + 60), control2: CGPoint(x: 50, y: top - 60))
        path.closeSubpath()
        fill(ctx, path, color.scaled(0.8))
        ctx.setStrokeColor(color.scaled(0.5).cg(0.4))
        ctx.setLineWidth(1.6)
        for f: CGFloat in [-0.5, 0, 0.5] {
            ctx.move(to: CGPoint(x: f * 30, y: top - 12))
            ctx.addQuadCurve(to: CGPoint(x: f * spread + trail * 0.7 + 3 * sin(w + f * 3), y: bottom + 14),
                             control: CGPoint(x: f * 46 + trail * 0.3, y: (top + bottom) / 2))
        }
        ctx.strokePath()
    }

    // MARK: Torso details

    private static func drawSuitLines(_ ctx: CGContext, _ look: HeroLook, top: CGFloat, hipY: CGFloat, body: Body) {
        // Muscle definition through the suit, plus side panels in the accent color.
        let hw = body.bw * body.waist, sw = body.bw * body.shoulder
        for sign: CGFloat in [-1, 1] {
            let panel = roundedPoly([CGPoint(x: sign * 24 * hw, y: hipY + 8), CGPoint(x: sign * 30 * hw, y: hipY + 8),
                                     CGPoint(x: sign * 44 * sw, y: top - 26), CGPoint(x: sign * 38 * sw, y: top - 28)], r: 2)
            fill(ctx, panel, look.accent.scaled(0.95), outline: 0)
        }
        ctx.setStrokeColor(look.suit.scaled(0.55).cg(0.5))
        ctx.setLineWidth(1.4)
        if body.feminine {
            drawBustLines(ctx, top: top, sw: sw)
        } else {
            for sign: CGFloat in [-1, 1] {
                ctx.move(to: CGPoint(x: sign * 2, y: top - 30))
                ctx.addQuadCurve(to: CGPoint(x: sign * 34 * sw, y: top - 26), control: CGPoint(x: sign * 20 * sw, y: top - 38))
            }
        }
        ctx.move(to: CGPoint(x: 0, y: top - 32)); ctx.addLine(to: CGPoint(x: 0, y: hipY + 16))
        ctx.strokePath()
    }

    /// Two soft curves suggesting the chest's shape under the suit (stroked by the caller).
    private static func drawBustLines(_ ctx: CGContext, top: CGFloat, sw: CGFloat) {
        for sign: CGFloat in [-1, 1] {
            ctx.move(to: CGPoint(x: sign * 5, y: top - 31))
            ctx.addQuadCurve(to: CGPoint(x: sign * 30 * sw, y: top - 25), control: CGPoint(x: sign * 15 * sw, y: top - 42))
        }
    }

    private static func drawTux(_ ctx: CGContext, _ look: HeroLook, top: CGFloat, hipY: CGFloat) {
        let shirt = roundedPoly([CGPoint(x: -12, y: top), CGPoint(x: 12, y: top), CGPoint(x: 0, y: top - 50)], r: 2)
        fill(ctx, shirt, RGB(0xF4F4F4), outline: 1.2)
        let tie = roundedPoly([CGPoint(x: -3, y: top - 2), CGPoint(x: 3, y: top - 2), CGPoint(x: 4.5, y: top - 40),
                               CGPoint(x: 0, y: top - 46), CGPoint(x: -4.5, y: top - 40)], r: 1)
        fill(ctx, tie, look.accent, outline: 1)
        for sign: CGFloat in [-1, 1] {
            let lapel = roundedPoly([CGPoint(x: sign * 13, y: top), CGPoint(x: sign * 26, y: top - 4),
                                     CGPoint(x: sign * 14, y: top - 26), CGPoint(x: sign * 2, y: top - 52)], r: 2)
            fill(ctx, lapel, look.suit.scaled(0.75), outline: 1)
        }
        ctx.setFillColor(look.suit.scaled(0.5).cg)
        for y: CGFloat in [top - 62, top - 74] { ctx.fillEllipse(in: CGRect(x: -2, y: y, width: 4, height: 4)) }
        // Pocket square.
        fill(ctx, roundedPoly([CGPoint(x: -30, y: top - 32), CGPoint(x: -20, y: top - 32), CGPoint(x: -22, y: top - 27)], r: 1), RGB(0xE8E8E8), outline: 0.8)
    }

    private static func drawMuscles(_ ctx: CGContext, _ look: HeroLook, top: CGFloat, hipY: CGFloat, body: Body) {
        let skin = look.skin
        let bw = body.bw * body.waist, sw = body.bw * body.shoulder
        ctx.setStrokeColor(skin.scaled(0.55).cg(0.55))
        ctx.setLineWidth(1.8)
        if body.feminine {
            // Toned abs below an athletic top in the accent color.
            ctx.move(to: CGPoint(x: 0, y: top - 62)); ctx.addLine(to: CGPoint(x: 0, y: hipY + 12))
            for y in stride(from: top - 70, to: hipY + 14, by: -11) {
                ctx.move(to: CGPoint(x: -10 * bw, y: y)); ctx.addQuadCurve(to: CGPoint(x: 10 * bw, y: y), control: CGPoint(x: 0, y: y - 2.5))
            }
            ctx.strokePath()
            let topPath = roundedPoly([CGPoint(x: -40 * sw, y: top - 14), CGPoint(x: -26 * sw, y: top - 2), CGPoint(x: -10, y: top - 12),
                                       CGPoint(x: 10, y: top - 12), CGPoint(x: 26 * sw, y: top - 2), CGPoint(x: 40 * sw, y: top - 14),
                                       CGPoint(x: 36 * sw, y: top - 42), CGPoint(x: -36 * sw, y: top - 42)], r: 6)
            fill(ctx, topPath, look.accent, outline: 1.4)
            ctx.setStrokeColor(look.accent.scaled(0.55).cg(0.6)); ctx.setLineWidth(1.4)
            drawBustLines(ctx, top: top, sw: sw)
            ctx.strokePath()
            return
        }
        for sign: CGFloat in [-1, 1] {
            ctx.move(to: CGPoint(x: sign * 2, y: top - 32))
            ctx.addQuadCurve(to: CGPoint(x: sign * 40 * sw, y: top - 24), control: CGPoint(x: sign * 22 * sw, y: top - 44))
            ctx.move(to: CGPoint(x: sign * 26 * bw, y: hipY + 8))
            ctx.addQuadCurve(to: CGPoint(x: sign * 38 * sw, y: top - 38), control: CGPoint(x: sign * 26 * sw, y: top - 50))
        }
        ctx.move(to: CGPoint(x: 0, y: top - 34)); ctx.addLine(to: CGPoint(x: 0, y: hipY + 12))
        for y in stride(from: top - 50, to: hipY + 14, by: -11) {
            ctx.move(to: CGPoint(x: -13 * bw, y: y)); ctx.addQuadCurve(to: CGPoint(x: 13 * bw, y: y), control: CGPoint(x: 0, y: y - 3))
        }
        ctx.strokePath()
    }

    private static func drawArmorChest(_ ctx: CGContext, _ look: HeroLook, top: CGFloat, hipY: CGFloat, body: Body) {
        let sw = body.bw * body.shoulder
        for sign: CGFloat in [-1, 1] {
            let pec = body.feminine
                ? roundedPoly([CGPoint(x: sign * 3, y: top - 4), CGPoint(x: sign * 38 * sw, y: top - 8), CGPoint(x: sign * 36 * sw, y: top - 30),
                               CGPoint(x: sign * 22 * sw, y: top - 40), CGPoint(x: sign * 6, y: top - 36)], r: 9)
                : roundedPoly([CGPoint(x: sign * 3, y: top - 2), CGPoint(x: sign * 40 * sw, y: top - 6),
                               CGPoint(x: sign * 38 * sw, y: top - 30), CGPoint(x: sign * 4, y: top - 38)], r: 5)
            fill(ctx, pec, look.suit.scaled(1.04), outline: 1.4)
        }
        for (row, y) in [top - 56, top - 68].enumerated() {
            for sign: CGFloat in [-1, 1] {
                let w: CGFloat = row == 0 ? 13 : 11
                let plate = CGPath(roundedRect: CGRect(x: sign > 0 ? 2 : -2 - w, y: y, width: w, height: 9), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
                fill(ctx, plate, look.accent, outline: 1)
            }
        }
        let beltW = 26 * body.bw * body.hip
        fill(ctx, CGPath(roundedRect: CGRect(x: -beltW, y: hipY + 4, width: beltW * 2, height: 8), cornerWidth: 3, cornerHeight: 3, transform: nil), look.suit.scaled(0.75), outline: 1)
        let c = CGPoint(x: 0, y: top - 24)
        fill(ctx, CGPath(ellipseIn: CGRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24), transform: nil), RGB(0x6E737C), outline: 1.4)
        glowSpot(ctx, at: c, radius: 22, alpha: 0.5)
        drawCore(ctx, look.emblemColor, at: c, r: 7.5)
        ctx.setStrokeColor(RGB(0x3A3E46).cg(0.8)); ctx.setLineWidth(1)
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            ctx.move(to: CGPoint(x: c.x + cos(a) * 8, y: c.y + sin(a) * 8))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * 11, y: c.y + sin(a) * 11))
        }
        ctx.strokePath()
    }

    private static func drawCore(_ ctx: CGContext, _ color: RGB, at c: CGPoint, r: CGFloat) {
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.clip()
        let g = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 1), color.cg, color.scaled(0.6).cg] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
        ctx.restoreGState()
    }

    // MARK: Head

    private static func coversHead(_ mask: HeroLook.Mask) -> Bool {
        mask == .cowl || mask == .helmet || mask == .armor || mask == .fullface
    }

    private static func drawHead(_ ctx: CGContext, _ look: HeroLook, _ p: Pose) {
        let fx = 2 + p.lookX * 2.5                       // 3/4 view: features turned toward the look direction
        let c = CGPoint(x: Rig.head.x, y: Rig.head.y)
        // Skull with a defined jaw.
        let head = CGMutablePath()
        let fem = look.isFeminine
        head.move(to: CGPoint(x: c.x - 18, y: c.y + 4))
        head.addCurve(to: CGPoint(x: c.x + 19, y: c.y + 6), control1: CGPoint(x: c.x - 19, y: c.y + 32), control2: CGPoint(x: c.x + 20, y: c.y + 32))
        if fem {
            // Softer jaw and a narrower, rounded chin.
            head.addCurve(to: CGPoint(x: c.x + 5, y: c.y - 20), control1: CGPoint(x: c.x + 19, y: c.y - 7), control2: CGPoint(x: c.x + 13, y: c.y - 17))
            head.addQuadCurve(to: CGPoint(x: c.x - 3, y: c.y - 20), control: CGPoint(x: c.x + 1, y: c.y - 22.5))
            head.addCurve(to: CGPoint(x: c.x - 18, y: c.y + 4), control1: CGPoint(x: c.x - 12, y: c.y - 17), control2: CGPoint(x: c.x - 18, y: c.y - 7))
        } else {
            head.addCurve(to: CGPoint(x: c.x + 8, y: c.y - 21), control1: CGPoint(x: c.x + 19, y: c.y - 8), control2: CGPoint(x: c.x + 16, y: c.y - 17))
            head.addQuadCurve(to: CGPoint(x: c.x - 6, y: c.y - 21), control: CGPoint(x: c.x + 1, y: c.y - 25))
            head.addCurve(to: CGPoint(x: c.x - 18, y: c.y + 4), control1: CGPoint(x: c.x - 15, y: c.y - 17), control2: CGPoint(x: c.x - 18, y: c.y - 8))
        }
        head.closeSubpath()

        let armor = look.mask == .armor
        if armor { metal = true }
        drawEars(ctx, look, c: c, behind: true)
        let headColor = coversHead(look.mask) ? look.maskColor : look.skin
        if look.mask == .none || look.mask == .domino || look.mask == .shades {
            // Human ear on the far side.
            fill(ctx, CGPath(ellipseIn: CGRect(x: c.x - 22, y: c.y - 6, width: 8, height: 13), transform: nil), look.skin.scaled(0.92), outline: 1.2)
        }
        fill(ctx, head, headColor, outline: 1.8)

        switch look.mask {
        case .armor:
            drawArmorFace(ctx, look, p, c: c, fx: fx)
            metal = look.outfit == .armor
            drawEars(ctx, look, c: c, behind: false)
            return
        case .fullface:
            drawLenses(ctx, look, p, c: c, fx: fx)
            drawEars(ctx, look, c: c, behind: false)
            return
        case .cowl:
            ctx.saveGState()
            ctx.addPath(head); ctx.clip()
            fill(ctx, CGPath(roundedRect: CGRect(x: c.x - 12 + fx, y: c.y - 26, width: 28, height: 22), cornerWidth: 9, cornerHeight: 9, transform: nil), look.skin, outline: 1.2)
            ctx.restoreGState()
        case .helmet:
            let visor = CGPath(roundedRect: CGRect(x: c.x - 15 + fx, y: c.y - 6, width: 33, height: 17), cornerWidth: 7, cornerHeight: 7, transform: nil)
            ctx.saveGState()
            ctx.addPath(visor); ctx.clip()
            let g = CGGradient(colorsSpace: space, colors: [RGB(0xD6F3FF).cg, RGB(0x5FB4E8).cg, RGB(0x2F6FA8).cg] as CFArray, locations: [0, 0.55, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: c.y + 11), end: CGPoint(x: 0, y: c.y - 6), options: [])
            ctx.restoreGState()
            ctx.addPath(visor); ctx.setStrokeColor(look.maskColor.scaled(0.4).cg); ctx.setLineWidth(1.6); ctx.strokePath()
        default:
            break
        }

        if look.mask == .domino {
            fill(ctx, CGPath(roundedRect: CGRect(x: c.x - 16 + fx, y: c.y, width: 34, height: 10), cornerWidth: 5, cornerHeight: 5, transform: nil), look.maskColor, outline: 1.2)
        }

        drawEyes(ctx, look, p, c: c, fx: fx)

        if look.mask == .shades {
            for dx: CGFloat in [-8, 9] {
                fill(ctx, CGPath(roundedRect: CGRect(x: c.x + fx + dx - 6.5, y: c.y + 0.5, width: 13, height: 8), cornerWidth: 3, cornerHeight: 3, transform: nil), look.maskColor, outline: 1)
            }
            line(ctx, [CGPoint(x: c.x + fx - 1.5, y: c.y + 5), CGPoint(x: c.x + fx + 2.5, y: c.y + 5)], look.maskColor.cg, width: 1.5)
        }
        if look.glasses && look.mask != .shades {
            ctx.setStrokeColor(RGB(0x2A2A2A).cg); ctx.setLineWidth(1.4)
            for dx: CGFloat in [-8, 9] { ctx.strokeEllipse(in: CGRect(x: c.x + fx + dx - 6, y: c.y - 1, width: 12, height: 11)) }
            line(ctx, [CGPoint(x: c.x + fx - 2, y: c.y + 5), CGPoint(x: c.x + fx + 3, y: c.y + 5)], RGB(0x2A2A2A).cg, width: 1.4)
        }

        let faceVisible = look.mask != .helmet
        if faceVisible {
            // Nose.
            line(ctx, [CGPoint(x: c.x + fx + 3, y: c.y - 3), CGPoint(x: c.x + fx + 4.5, y: c.y - 9), CGPoint(x: c.x + fx + 1.5, y: c.y - 10)],
                 look.skin.scaled(0.6).cg(0.7), width: 1.3)
            if look.beard == true && !fem { drawBeard(ctx, look.hair, c: c, fx: fx, head: head) }
            drawMouth(ctx, p, at: CGPoint(x: c.x + fx + 1.5, y: c.y - 15), lip: look.skin.scaled(0.5),
                      tint: fem ? look.skin.mixed(with: RGB(0xB8405A), 0.55) : nil)
        }
        if !coversHead(look.mask) { drawFrontHair(ctx, look, c: c) }
        drawEars(ctx, look, c: c, behind: false)
    }

    private static func drawEyes(_ ctx: CGContext, _ look: HeroLook, _ p: Pose, c: CGPoint, fx: CGFloat) {
        let masked = look.mask == .domino || look.mask == .cowl
        for dx: CGFloat in [-8, 9] {
            let e = CGPoint(x: c.x + fx + dx, y: c.y + 4)
            if p.eyesOpen < 0.2 {
                ctx.setStrokeColor(ink.cg); ctx.setLineWidth(1.6)
                ctx.move(to: CGPoint(x: e.x - 4, y: e.y))
                ctx.addQuadCurve(to: CGPoint(x: e.x + 4, y: e.y), control: CGPoint(x: e.x, y: e.y + (p.smile > 0.5 ? 3 : -2)))
                ctx.strokePath()
            } else {
                let open = min(1.15, p.eyesOpen)
                // Almond-shaped eye.
                let eye = CGMutablePath()
                eye.move(to: CGPoint(x: e.x - 5, y: e.y))
                eye.addQuadCurve(to: CGPoint(x: e.x + 5, y: e.y + 0.5), control: CGPoint(x: e.x, y: e.y + 5 * open))
                eye.addQuadCurve(to: CGPoint(x: e.x - 5, y: e.y), control: CGPoint(x: e.x, y: e.y - 3.5 * open))
                eye.closeSubpath()
                ctx.addPath(eye)
                ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
                ctx.fillPath()
                if !masked || look.mask == .domino {
                    ctx.saveGState()
                    ctx.addPath(eye); ctx.clip()
                    let iris = CGPoint(x: e.x + 0.8 + p.lookX * 1.4, y: e.y + 0.6 + p.lookY * 1)
                    ctx.setFillColor(RGB(0x4A3426).cg)
                    ctx.fillEllipse(in: CGRect(x: iris.x - 2.8, y: iris.y - 2.8, width: 5.6, height: 5.6))
                    ctx.setFillColor(ink.cg)
                    ctx.fillEllipse(in: CGRect(x: iris.x - 1.4, y: iris.y - 1.4, width: 2.8, height: 2.8))
                    ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
                    ctx.fillEllipse(in: CGRect(x: iris.x - 1.6, y: iris.y + 0.4, width: 1.3, height: 1.3))
                    ctx.restoreGState()
                }
                ctx.addPath(eye)
                ctx.setStrokeColor(ink.cg); ctx.setLineWidth(1.2)
                ctx.strokePath()
                if look.isFeminine && look.mask != .cowl {
                    // A heavier upper lid with a small wing of lashes at the outer corner.
                    let outer: CGFloat = dx < 0 ? -1 : 1
                    ctx.setLineWidth(2)
                    ctx.move(to: CGPoint(x: e.x - 5, y: e.y + 0.3))
                    ctx.addQuadCurve(to: CGPoint(x: e.x + 5, y: e.y + 0.8), control: CGPoint(x: e.x, y: e.y + 5 * open))
                    ctx.move(to: CGPoint(x: e.x + outer * 4.5, y: e.y + 1.2))
                    ctx.addLine(to: CGPoint(x: e.x + outer * 7.5, y: e.y + 3.4))
                    ctx.move(to: CGPoint(x: e.x + outer * 3, y: e.y + 2.8 * open))
                    ctx.addLine(to: CGPoint(x: e.x + outer * 5.2, y: e.y + 4.6 * open))
                    ctx.strokePath()
                }
            }
            // Brows.
            if look.mask != .helmet && look.mask != .cowl {
                let inner = dx < 0 ? e.x + 4 : e.x - 4, outer = dx < 0 ? e.x - 5 : e.x + 5
                ctx.setStrokeColor(look.hair.scaled(0.75).cg)
                ctx.setLineWidth(look.isFeminine ? 1.5 : 2.2)
                ctx.move(to: CGPoint(x: outer, y: e.y + 6 + 1.2 * p.brow))
                if look.isFeminine {
                    ctx.addQuadCurve(to: CGPoint(x: inner, y: e.y + 6.5 + 2.4 * p.brow - 0.6),
                                     control: CGPoint(x: (outer + inner) / 2, y: e.y + 8.5 + 1.8 * p.brow))
                } else {
                    ctx.addLine(to: CGPoint(x: inner, y: e.y + 6 + 2.4 * p.brow - 0.6))
                }
                ctx.strokePath()
            }
        }
    }

    private static func drawMouth(_ ctx: CGContext, _ p: Pose, at m: CGPoint, lip: RGB, tint: RGB? = nil) {
        if let tint, p.mouthOpen <= 0.15 {
            // Fuller, tinted lips.
            let lips = CGMutablePath()
            lips.move(to: CGPoint(x: m.x - 4.5, y: m.y + 0.5))
            lips.addQuadCurve(to: CGPoint(x: m.x + 4.5, y: m.y + 0.5), control: CGPoint(x: m.x, y: m.y + 3.2 - 2 * p.smile))
            lips.addQuadCurve(to: CGPoint(x: m.x - 4.5, y: m.y + 0.5), control: CGPoint(x: m.x, y: m.y - 3.6 - 3 * p.smile))
            lips.closeSubpath()
            ctx.addPath(lips)
            ctx.setFillColor(tint.cg)
            ctx.fillPath()
        }
        if p.mouthOpen > 0.15 {
            let h = 2.5 + 5 * p.mouthOpen
            let mouth = CGMutablePath()
            mouth.move(to: CGPoint(x: m.x - 5, y: m.y + 1))
            mouth.addQuadCurve(to: CGPoint(x: m.x + 5, y: m.y + 1), control: CGPoint(x: m.x, y: m.y + 1 + p.smile * 1.5))
            mouth.addQuadCurve(to: CGPoint(x: m.x - 5, y: m.y + 1), control: CGPoint(x: m.x, y: m.y + 1 - h * 1.6))
            ctx.addPath(mouth)
            ctx.setFillColor(RGB(0x4A1C24).cg)
            ctx.fillPath()
        } else {
            ctx.setStrokeColor((tint?.scaled(0.6) ?? lip).cg); ctx.setLineWidth(tint == nil ? 1.5 : 1.1)
            ctx.move(to: CGPoint(x: m.x - 4.5, y: m.y + 0.5))
            ctx.addQuadCurve(to: CGPoint(x: m.x + 4.5, y: m.y + 0.5), control: CGPoint(x: m.x, y: m.y + 0.5 - 4 * p.smile))
            ctx.strokePath()
        }
    }

    private static func drawBeard(_ ctx: CGContext, _ hair: RGB, c: CGPoint, fx: CGFloat, head: CGPath) {
        ctx.saveGState()
        ctx.addPath(head); ctx.clip()
        let beard = CGMutablePath()
        beard.move(to: CGPoint(x: c.x - 20, y: c.y - 2))
        beard.addCurve(to: CGPoint(x: c.x + 21, y: c.y - 2), control1: CGPoint(x: c.x - 14, y: c.y - 34), control2: CGPoint(x: c.x + 16, y: c.y - 34))
        beard.addLine(to: CGPoint(x: c.x + 15, y: c.y - 2))
        beard.addCurve(to: CGPoint(x: c.x - 14, y: c.y - 2), control1: CGPoint(x: c.x + 10, y: c.y - 14), control2: CGPoint(x: c.x - 8, y: c.y - 14))
        beard.closeSubpath()
        fill(ctx, beard, hair.scaled(1.15), outline: 0)
        ctx.restoreGState()
        let stache = CGPath(roundedRect: CGRect(x: c.x + fx - 4.5, y: c.y - 13.5, width: 12, height: 3.5), cornerWidth: 1.7, cornerHeight: 1.7, transform: nil)
        fill(ctx, stache, hair.scaled(1.15), outline: 0)
    }

    private static func drawFrontHair(_ ctx: CGContext, _ look: HeroLook, c: CGPoint) {
        let color = look.hair
        switch look.hairStyle {
        case .bald:
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.2))
            ctx.fillEllipse(in: CGRect(x: c.x - 9, y: c.y + 17, width: 10, height: 5))
            return
        case .spiky:
            for (i, x) in [-14, -6, 2, 10, 17].enumerated() {
                let base = CGFloat(x)
                fill(ctx, roundedPoly([CGPoint(x: c.x + base - 6, y: c.y + 20), CGPoint(x: c.x + base * 1.2 - 3, y: c.y + 36 + CGFloat(i % 2) * 4),
                                       CGPoint(x: c.x + base + 6, y: c.y + 20)], r: 1.5), color, outline: 1.2)
            }
        case .bun:
            fill(ctx, CGPath(ellipseIn: CGRect(x: c.x - 9, y: c.y + 22, width: 16, height: 14), transform: nil), color, outline: 1.2)
        default:
            break
        }
        // Cap of hair over the skull with a side part.
        let cap = CGMutablePath()
        cap.move(to: CGPoint(x: c.x - 19, y: c.y + 2))
        cap.addCurve(to: CGPoint(x: c.x + 20, y: c.y + 10), control1: CGPoint(x: c.x - 22, y: c.y + 34), control2: CGPoint(x: c.x + 22, y: c.y + 34))
        cap.addQuadCurve(to: CGPoint(x: c.x + 2, y: c.y + 16), control: CGPoint(x: c.x + 12, y: c.y + 14))
        cap.addQuadCurve(to: CGPoint(x: c.x - 14, y: c.y + 8), control: CGPoint(x: c.x - 8, y: c.y + 16))
        cap.addLine(to: CGPoint(x: c.x - 15, y: c.y - 6))
        cap.closeSubpath()
        fill(ctx, cap, color, outline: 1.4)
        line(ctx, [CGPoint(x: c.x - 4, y: c.y + 27), CGPoint(x: c.x + 4, y: c.y + 17)], color.scaled(0.6).cg(0.6), width: 1)
        if look.isFeminine && (look.hairStyle == .long || look.hairStyle == .curly) {
            // Locks falling past the cheeks.
            let back = CGMutablePath()
            back.move(to: CGPoint(x: c.x - 19, y: c.y + 6))
            back.addCurve(to: CGPoint(x: c.x - 18, y: c.y - 26), control1: CGPoint(x: c.x - 25, y: c.y - 6), control2: CGPoint(x: c.x - 24, y: c.y - 20))
            back.addQuadCurve(to: CGPoint(x: c.x - 13, y: c.y + 4), control: CGPoint(x: c.x - 13, y: c.y - 10))
            back.closeSubpath()
            fill(ctx, back, color, outline: 1.3)
            let front = CGMutablePath()
            front.move(to: CGPoint(x: c.x + 20, y: c.y + 10))
            front.addCurve(to: CGPoint(x: c.x + 21, y: c.y - 24), control1: CGPoint(x: c.x + 26, y: c.y - 4), control2: CGPoint(x: c.x + 26, y: c.y - 18))
            front.addQuadCurve(to: CGPoint(x: c.x + 16, y: c.y + 6), control: CGPoint(x: c.x + 15, y: c.y - 8))
            front.closeSubpath()
            fill(ctx, front, color, outline: 1.3)
        }
        if look.hairStyle == .curly {
            for (x, y) in [(-14, 22), (-6, 28), (4, 28), (13, 22)] {
                fill(ctx, CGPath(ellipseIn: CGRect(x: c.x + CGFloat(x) - 6, y: c.y + CGFloat(y) - 4, width: 12, height: 11), transform: nil), color, outline: 1)
            }
        }
    }

    private static func drawBackHair(_ ctx: CGContext, _ look: HeroLook, _ p: Pose, drop: CGFloat) {
        let c = CGPoint(x: Rig.head.x, y: Rig.head.y - drop)
        let color = look.hair.scaled(0.85)
        switch look.hairStyle {
        case .long:
            fill(ctx, CGPath(roundedRect: CGRect(x: c.x - 22, y: c.y - 36, width: 42, height: 64), cornerWidth: 16, cornerHeight: 16, transform: nil), color, outline: 1.4)
        case .ponytail:
            let sway = 3 * sin(p.capeWave * 0.8)
            let tail = CGMutablePath()
            tail.move(to: CGPoint(x: c.x - 14, y: c.y + 18))
            tail.addCurve(to: CGPoint(x: c.x - 30 + sway, y: c.y - 30), control1: CGPoint(x: c.x - 34, y: c.y + 22), control2: CGPoint(x: c.x - 38 + sway, y: c.y - 6))
            tail.addCurve(to: CGPoint(x: c.x - 16, y: c.y + 4), control1: CGPoint(x: c.x - 24 + sway, y: c.y - 22), control2: CGPoint(x: c.x - 20, y: c.y - 4))
            tail.closeSubpath()
            fill(ctx, tail, color, outline: 1.4)
        case .curly:
            fill(ctx, CGPath(ellipseIn: CGRect(x: c.x - 25, y: c.y - 14, width: 50, height: 50), transform: nil), color, outline: 1.4)
        default: break
        }
    }

    private static func drawEars(_ ctx: CGContext, _ look: HeroLook, c: CGPoint, behind: Bool) {
        let color = look.mask == .none || look.mask == .shades ? look.hair : look.maskColor
        switch look.ears {
        case .pointy, .cat:
            guard behind else { return }
            for sign: CGFloat in [-1, 1] {
                let base = c.x + sign * 10
                fill(ctx, roundedPoly([CGPoint(x: base - 6, y: c.y + 18), CGPoint(x: base + sign * 4, y: c.y + 40), CGPoint(x: base + 6, y: c.y + 18)], r: 1.5), color, outline: 1.4)
                if look.ears == .cat {
                    fill(ctx, roundedPoly([CGPoint(x: base - 2.5, y: c.y + 21), CGPoint(x: base + sign * 2.5, y: c.y + 33), CGPoint(x: base + 2.5, y: c.y + 21)], r: 1), RGB(0xF4A6C0), outline: 0)
                }
            }
        case .antenna:
            guard !behind else { return }
            line(ctx, [CGPoint(x: c.x + 4, y: c.y + 24), CGPoint(x: c.x + 9, y: c.y + 40)], look.accent.scaled(0.6).cg, width: 2)
            fill(ctx, CGPath(ellipseIn: CGRect(x: c.x + 5, y: c.y + 37, width: 8, height: 8), transform: nil), look.accent, outline: 1)
        case .none: break
        }
    }

    /// Sculpted gold faceplate, ear discs and glowing eye slits.
    private static func drawArmorFace(_ ctx: CGContext, _ look: HeroLook, _ p: Pose, c: CGPoint, fx: CGFloat) {
        let x = c.x + fx * 0.8
        line(ctx, [CGPoint(x: c.x - 1, y: c.y + 28), CGPoint(x: c.x, y: c.y + 18)], look.maskColor.scaled(0.3).cg(0.7), width: 1.2)
        fill(ctx, CGPath(ellipseIn: CGRect(x: c.x - 22, y: c.y - 6, width: 9, height: 12), transform: nil), look.maskColor.scaled(0.85), outline: 1.2)
        let plate = roundedPoly([
            CGPoint(x: x - 7, y: c.y + 20), CGPoint(x: x + 8, y: c.y + 20), CGPoint(x: x + 12, y: c.y + 12), CGPoint(x: x + 16, y: c.y + 2),
            CGPoint(x: x + 13, y: c.y - 12), CGPoint(x: x + 6, y: c.y - 20), CGPoint(x: x - 5, y: c.y - 20), CGPoint(x: x - 12, y: c.y - 12),
            CGPoint(x: x - 15, y: c.y + 2), CGPoint(x: x - 11, y: c.y + 12),
        ], r: 2.5)
        fill(ctx, plate, look.accent, outline: 1.4)
        let groove = look.accent.scaled(0.4).cg(0.75)
        for sign: CGFloat in [-1, 1] {
            line(ctx, [CGPoint(x: x + sign * 12, y: c.y - 1), CGPoint(x: x + sign * 8, y: c.y - 9), CGPoint(x: x + sign * 4, y: c.y - 19)], groove, width: 1)
            line(ctx, [CGPoint(x: x + sign * 7, y: c.y + 19), CGPoint(x: x + sign * 10, y: c.y + 10)], groove, width: 1)
        }
        line(ctx, [CGPoint(x: x - 6, y: c.y - 13), CGPoint(x: x - 2, y: c.y - 14), CGPoint(x: x + 3, y: c.y - 14), CGPoint(x: x + 7, y: c.y - 13)], groove, width: 1.3)
        let lit = p.eyesOpen > 0.2
        for sign: CGFloat in [-1, 1] {
            let ex = x + sign * 7 + 0.5
            let slit = roundedPoly([CGPoint(x: ex - sign * 5, y: c.y + 4.5), CGPoint(x: ex + sign * 5.5, y: c.y + 5.5),
                                    CGPoint(x: ex + sign * 4.5, y: c.y + 2), CGPoint(x: ex - sign * 4.5, y: c.y + 2)], r: 0.6)
            ctx.addPath(slit)
            ctx.setFillColor(RGB(0x1E2328).cg)
            ctx.fillPath()
            if lit {
                glowSpot(ctx, at: CGPoint(x: ex, y: c.y + 3.5), radius: 10, alpha: 0.7)
                ctx.addPath(slit)
                ctx.setFillColor(CGColor(srgbRed: 0.88, green: 1, blue: 1, alpha: 1))
                ctx.fillPath()
            }
        }
    }

    /// Full-face mask with large white lenses that narrow when blinking.
    private static func drawLenses(_ ctx: CGContext, _ look: HeroLook, _ p: Pose, c: CGPoint, fx: CGFloat) {
        line(ctx, [CGPoint(x: c.x + fx * 0.6, y: c.y + 28), CGPoint(x: c.x + fx * 0.6, y: c.y - 22)], look.maskColor.scaled(0.45).cg(0.5), width: 1)
        let open = max(0.15, min(1.1, p.eyesOpen))
        for sign: CGFloat in [-1, 1] {
            let ex = c.x + fx + sign * 8.5
            let h = 11 * open
            let lens = CGMutablePath()
            lens.move(to: CGPoint(x: ex - sign * 3, y: c.y + 1))
            lens.addCurve(to: CGPoint(x: ex + sign * 8, y: c.y + 2 + h * 0.7),
                          control1: CGPoint(x: ex + sign * 2, y: c.y - 1), control2: CGPoint(x: ex + sign * 9, y: c.y + 1))
            lens.addCurve(to: CGPoint(x: ex - sign * 3, y: c.y + 1),
                          control1: CGPoint(x: ex + sign * 2, y: c.y + 4 + h), control2: CGPoint(x: ex - sign * 6, y: c.y + 3 + h * 0.5))
            lens.closeSubpath()
            ctx.addPath(lens)
            ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
            ctx.fillPath()
            ctx.addPath(lens)
            ctx.setStrokeColor(RGB(0x15151A).cg)
            ctx.setLineWidth(2.2)
            ctx.strokePath()
        }
    }

    // MARK: Paint

    /// Satin finish: side-lit gradient, a soft top sheen and a crisp outline.
    static func fill(_ ctx: CGContext, _ path: CGPath, _ color: RGB, outline: CGFloat = 1.8) {
        if metal { return metalFill(ctx, path, color, outline: outline) }
        let b = path.boundingBox
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(satinGradient(color), start: CGPoint(x: b.minX, y: b.midY + b.height * 0.15),
                               end: CGPoint(x: b.maxX, y: b.midY - b.height * 0.15),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // Rim light along the lit edge.
        ctx.setLineWidth(3)
        ctx.translateBy(x: 1.2, y: -0.8)
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
        ctx.strokePath()
        ctx.restoreGState()
        if outline > 0 {
            ctx.addPath(path)
            ctx.setStrokeColor(color.scaled(0.35).cg)
            ctx.setLineWidth(outline)
            ctx.strokePath()
        }
    }

    private static func satinGradient(_ c: RGB) -> CGGradient {
        if let g = satinGradients[c] { return g }
        let g = CGGradient(colorsSpace: space, colors: [c.scaled(1.22).cg, c.scaled(1.02).cg, c.scaled(0.7).cg] as CFArray,
                           locations: [0, 0.4, 1])!
        satinGradients[c] = g
        return g
    }

    private static func metalGradient(_ c: RGB) -> CGGradient {
        if let g = metalGradients[c] { return g }
        let g = CGGradient(colorsSpace: space,
                           colors: [c.scaled(1.55).cg, c.scaled(1.12).cg, c.scaled(0.58).cg, c.scaled(0.92).cg, c.scaled(0.45).cg] as CFArray,
                           locations: [0, 0.2, 0.5, 0.72, 1])!
        metalGradients[c] = g
        return g
    }

    /// Polished metal: banded reflections, a sharp specular sheen, and a beveled light edge.
    private static func metalFill(_ ctx: CGContext, _ path: CGPath, _ color: RGB, outline: CGFloat) {
        let b = path.boundingBox
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(metalGradient(color), start: CGPoint(x: b.minX, y: b.maxY), end: CGPoint(x: b.maxX, y: b.minY),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.saveGState()
        ctx.translateBy(x: b.minX + b.width * 0.32, y: b.minY + b.height * 0.74)
        ctx.scaleBy(x: 1, y: 0.55)
        let spec = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.75), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(spec, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: max(2, min(b.width, b.height) * 0.38), options: [])
        ctx.restoreGState()
        ctx.setLineWidth(2)
        ctx.translateBy(x: 0.9, y: -0.9)
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.strokePath()
        ctx.translateBy(x: -1.8, y: 1.8)
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.25))
        ctx.strokePath()
        ctx.restoreGState()
        if outline > 0 {
            ctx.addPath(path)
            ctx.setStrokeColor(color.scaled(0.3).cg)
            ctx.setLineWidth(min(outline, 1.6))
            ctx.strokePath()
        }
    }

    private static func line(_ ctx: CGContext, _ pts: [CGPoint], _ color: CGColor, width: CGFloat) {
        guard let first = pts.first else { return }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.move(to: first)
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
    }

    /// Soft glow (eyes, core, repulsors, thrusters).
    private static func glowSpot(_ ctx: CGContext, at c: CGPoint, radius: CGFloat, alpha: CGFloat = 1) {
        let g = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: alpha), glow.cg(0.8 * alpha), glow.cg(0)] as CFArray,
                           locations: [0, 0.35, 1])!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: radius, options: [])
    }

    static func roundedPoly(_ pts: [CGPoint], r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let n = pts.count
        path.move(to: CGPoint(x: (pts[n - 1].x + pts[0].x) / 2, y: (pts[n - 1].y + pts[0].y) / 2))
        for i in 0..<n { path.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % n], radius: max(0, r)) }
        path.closeSubpath()
        return path
    }

    static func emblem(_ kind: HeroLook.Emblem, size s: CGFloat) -> CGPath {
        switch kind {
        case .none:
            return CGMutablePath()
        case .core, .circle:
            return CGPath(ellipseIn: CGRect(x: -s, y: -s * 0.85, width: s * 2, height: s * 1.7), transform: nil)
        case .star:
            let pts = (0..<10).map { i -> CGPoint in
                let a = CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let r = i % 2 == 0 ? s * 1.1 : s * 0.48
                return CGPoint(x: cos(a) * r, y: sin(a) * r)
            }
            return roundedPoly(pts, r: 1)
        case .bolt:
            return roundedPoly([(-0.15, 1.1), (0.55, 1.1), (0.12, 0.2), (0.55, 0.2), (-0.35, -1.15), (-0.05, -0.1), (-0.5, -0.1)]
                .map { CGPoint(x: $0.0 * s, y: $0.1 * s) }, r: 1)
        case .drop:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: s * 1.1))
            p.addCurve(to: CGPoint(x: 0, y: -s * 0.9), control1: CGPoint(x: s, y: 0), control2: CGPoint(x: s * 0.75, y: -s * 0.9))
            p.addCurve(to: CGPoint(x: 0, y: s * 1.1), control1: CGPoint(x: -s * 0.75, y: -s * 0.9), control2: CGPoint(x: -s, y: 0))
            p.closeSubpath()
            return p
        case .diamond:
            return roundedPoly([CGPoint(x: 0, y: s * 1.1), CGPoint(x: s * 0.8, y: 0), CGPoint(x: 0, y: -s * 1.1), CGPoint(x: -s * 0.8, y: 0)], r: 1.5)
        case .spider:
            var shape = CGPath(ellipseIn: CGRect(x: -s * 0.28, y: -s * 0.95, width: s * 0.56, height: s * 1.0), transform: nil)
            shape = shape.union(CGPath(ellipseIn: CGRect(x: -s * 0.2, y: s * 0.12, width: s * 0.4, height: s * 0.44), transform: nil))
            let legs: [[(CGFloat, CGFloat)]] = [
                [(0.1, 0.42), (0.55, 0.8), (0.62, 1.2)], [(0.12, 0.32), (0.72, 0.5), (0.9, 0.95)],
                [(0.12, 0.05), (0.72, -0.12), (0.9, -0.62)], [(0.1, -0.08), (0.55, -0.5), (0.62, -1.15)],
            ]
            let strokes = CGMutablePath()
            for leg in legs {
                for side: CGFloat in [1, -1] {
                    strokes.addLines(between: leg.map { CGPoint(x: $0.0 * s * side, y: $0.1 * s) })
                }
            }
            shape = shape.union(strokes.copy(strokingWithWidth: s * 0.13, lineCap: .round, lineJoin: .round, miterLimit: 4))
            return shape
        case .heart:
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: -s))
            p.addCurve(to: CGPoint(x: -s, y: s * 0.35), control1: CGPoint(x: -s * 0.5, y: -s * 0.45), control2: CGPoint(x: -s, y: -s * 0.1))
            p.addCurve(to: CGPoint(x: 0, y: s * 0.55), control1: CGPoint(x: -s, y: s * 0.95), control2: CGPoint(x: -s * 0.15, y: s))
            p.addCurve(to: CGPoint(x: s, y: s * 0.35), control1: CGPoint(x: s * 0.15, y: s), control2: CGPoint(x: s, y: s * 0.95))
            p.addCurve(to: CGPoint(x: 0, y: -s), control1: CGPoint(x: s, y: -s * 0.1), control2: CGPoint(x: s * 0.5, y: -s * 0.45))
            p.closeSubpath()
            return p
        }
    }

    // MARK: Snapshots (previews, thumbnails)

    static func image(_ look: HeroLook, _ pose: Pose, height px: Int) -> CGImage? {
        let w = Int(CGFloat(px) * 1.0)
        guard let ctx = CGContext(data: nil, width: w, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let s = CGFloat(px) / (height + 80)
        ctx.translateBy(x: CGFloat(w) / 2, y: 10 * s)
        ctx.scaleBy(x: s, y: s)
        draw(ctx, look, pose)
        return ctx.makeImage()
    }
}

extension RGB {
    var cg: CGColor { CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1) }
    func cg(_ alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: alpha)
    }
}
