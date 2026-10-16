import AppKit

struct Bubble: Equatable {
    var title: String
    var subtitle: String?
}

/// A floating emoji effect (sparkles, drops, hearts, Zzz) in character units, relative to the feet.
struct Particle {
    var text: String
    var x: CGFloat
    var y: CGFloat
    var vx: CGFloat
    var vy: CGFloat
    var life: CGFloat
    let maxLife: CGFloat
    var size: CGFloat
    var gravity: CGFloat = 0
}

/// Draws the buddy (a live plush rig or sprite frames), its effects, and a speech bubble.
final class BuddyView: NSView {
    var puppet: Puppet = .rig(HeroLook.presets[0])
    var image: CGImage?
    var pose = Pose()
    var facingRight = true
    var spriteSize = CGSize(width: 150, height: 180)
    var bubble: Bubble?
    var particles: [Particle] = []

    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?

    private(set) var bubbleRect: CGRect = .zero
    private var downPoint: NSPoint?
    private var dragging = false

    /// The character's standing box: feet on the bottom edge, ~250 rig units tall.
    var spriteRect: CGRect {
        CGRect(x: ((bounds.width - spriteSize.width) / 2).rounded(), y: 6,
               width: spriteSize.width.rounded(), height: spriteSize.height.rounded())
    }

    private var unit: CGFloat { spriteRect.height / HeroRenderer.height }

    override var isOpaque: Bool { false }

    /// Area that should receive clicks; everything else passes through to the apps below.
    var hitRect: CGRect {
        let body = spriteRect.offsetBy(dx: 0, dy: pose.lift * unit).insetBy(dx: -spriteRect.width * 0.1, dy: 0)
        return bubble == nil ? body : body.union(bubbleRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        let r = spriteRect
        let flip: CGFloat = facingRight ? 1 : -1

        ctx.saveGState()
        ctx.translateBy(x: r.midX, y: r.minY)
        switch puppet {
        case .rig(let look):
            ctx.scaleBy(x: unit * flip, y: unit)
            HeroRenderer.draw(ctx, look, pose)
        case .frames:
            // Sprite frames get the same squash, lean and hops as the rig.
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.16 * max(0.35, 1 - pose.lift / 160)))
            ctx.fillEllipse(in: CGRect(x: -r.width * 0.35, y: -5, width: r.width * 0.7, height: 10))
            if let image {
                ctx.translateBy(x: 0, y: pose.lift * unit)
                ctx.rotate(by: -pose.lean * flip)
                ctx.scaleBy(x: flip / sqrt(max(0.5, pose.squash)), y: pose.squash)
                ctx.interpolationQuality = CGFloat(image.height) < r.height ? .none : .high
                ctx.draw(image, in: CGRect(x: -r.width / 2, y: 0, width: r.width, height: r.height))
            }
        }
        ctx.restoreGState()

        drawParticles(ctx)
        drawBubble()
    }

    private func drawParticles(_ ctx: CGContext) {
        let r = spriteRect
        for p in particles {
            let alpha = min(1, p.life / (p.maxLife * 0.35))
            let font = NSFont.systemFont(ofSize: p.size * unit)
            let text = NSAttributedString(string: p.text, attributes: [
                .font: font, .foregroundColor: NSColor(calibratedRed: 0.55, green: 0.75, blue: 1, alpha: 1),
            ])
            let size = text.size()
            ctx.saveGState()
            ctx.setAlpha(alpha)
            let x = r.midX + p.x * unit * (facingRight ? 1 : -1)
            text.draw(at: NSPoint(x: x - size.width / 2, y: r.minY + p.y * unit - size.height / 2))
            ctx.restoreGState()
        }
    }

    private func drawBubble() {
        guard let bubble else { bubbleRect = .zero; return }
        let ink = NSColor(calibratedRed: 0.17, green: 0.11, blue: 0.10, alpha: 1)
        let para = NSMutableParagraphStyle()
        para.alignment = .center

        let text = NSMutableAttributedString(string: bubble.title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: ink,
            .paragraphStyle: para,
        ])
        if let sub = bubble.subtitle {
            text.append(NSAttributedString(string: "\n" + sub, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 1),
                .paragraphStyle: para,
            ]))
        }

        let maxText = min(bounds.width - 30, 210)
        let size = text.boundingRect(with: CGSize(width: maxText, height: 200), options: .usesLineFragmentOrigin).size
        let w = ceil(size.width) + 24, h = ceil(size.height) + 14
        let top = spriteRect.minY + 262 * unit
        let r = CGRect(x: ((bounds.width - w) / 2).rounded(), y: (top + 14).rounded(), width: w, height: h)
        bubbleRect = r.insetBy(dx: -2, dy: -12)

        let box = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        NSColor.white.setFill()
        box.fill()
        ink.setStroke()
        box.lineWidth = 2
        box.stroke()

        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: r.midX - 7, y: r.minY))
        tail.line(to: NSPoint(x: r.midX, y: r.minY - 9))
        tail.line(to: NSPoint(x: r.midX + 7, y: r.minY))
        tail.fill()
        tail.lineWidth = 2
        tail.stroke()
        NSColor.white.setFill()
        NSRect(x: r.midX - 6, y: r.minY - 1, width: 12, height: 3).fill()

        text.draw(with: CGRect(x: r.minX + 12, y: r.minY + 7, width: w - 24, height: ceil(size.height) + 2),
                  options: .usesLineFragmentOrigin)
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onContextMenu?(event); return }
        downPoint = NSEvent.mouseLocation
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let p = NSEvent.mouseLocation
        if !dragging && hypot(p.x - start.x, p.y - start.y) > 4 {
            dragging = true
            onDragStart?()
        }
        if dragging { onDrag?(p) }
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            onDragEnd?()
        } else if downPoint != nil {
            if event.clickCount >= 2 { onDoubleClick?() } else { onClick?() }
        }
        downPoint = nil
        dragging = false
    }

    override func rightMouseDown(with event: NSEvent) { onContextMenu?(event) }
}
