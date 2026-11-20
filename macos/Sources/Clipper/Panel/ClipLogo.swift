import AppKit

/// The "clip" logo drawn in code so it stays crisp at menu-bar sizes and can
/// be animated frame by frame.
///
/// The mark is the logo's `ip` ligature: a single rounded stroke that rises
/// as the `i`, arcs over the top and folds back into the `p` bowl – which is
/// also the silhouette of a paperclip. The wordmark adds the `c` and `l`.
/// All images are template images, so they follow the menu bar's light/dark
/// appearance and the highlighted state automatically.
enum ClipLogo {
    enum Style { case mark, wordmark }

    static let height: CGFloat = 18
    private static let lineWidth: CGFloat = 1.7

    static func size(_ style: Style) -> NSSize {
        NSSize(width: style == .mark ? 18 : 30, height: height)
    }

    /// - Parameters:
    ///   - progress: 0…1 – how much of the stroke is drawn (draw-on effect).
    ///     The undrawn remainder is shown faintly so the icon never vanishes.
    ///   - lift: vertical offset in points (bounce).
    ///   - squeeze: 0…1 – horizontal pinch, like a clip being pressed.
    static func image(_ style: Style, progress: CGFloat = 1, lift: CGFloat = 0, squeeze: CGFloat = 0) -> NSImage {
        let size = size(style)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            // Pinch around the mark's centre, then lift.
            let markCenterX = style == .mark ? 9.0 : rect.width - 9.0
            ctx.translateBy(x: markCenterX, y: lift)
            ctx.scaleBy(x: 1 - 0.18 * squeeze, y: 1 + 0.06 * squeeze)
            ctx.translateBy(x: -markCenterX, y: 0)

            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            if style == .wordmark { appendLetters(to: path) }
            appendMark(to: path, originX: style == .mark ? 0 : rect.width - 18)

            let p = max(0, min(1, progress))
            if p >= 1 {
                NSColor.black.setStroke()
                path.stroke()
            } else {
                NSColor.black.withAlphaComponent(0.28).setStroke()
                path.stroke()
                let total = length(of: path)
                let drawn = path.copy() as! NSBezierPath
                drawn.setLineDash([max(0.01, total * p), total + 1], count: 2, phase: 0)
                NSColor.black.setStroke()
                drawn.stroke()
            }
            ctx.restoreGState()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Clipper"
        return img
    }

    /// The `ip` paperclip in an 18 × 18 box (y up). Baseline 4.5, x-height 13.
    private static func appendMark(to path: NSBezierPath, originX x: CGFloat) {
        // i stem, starting below the baseline (the p descender).
        path.move(to: NSPoint(x: x + 5, y: 1.8))
        path.line(to: NSPoint(x: x + 5, y: 11.4))
        // Outer arch over the top.
        path.appendArc(withCenter: NSPoint(x: x + 9, y: 11.4), radius: 4, startAngle: 180, endAngle: 0, clockwise: true)
        // Right side down…
        path.line(to: NSPoint(x: x + 13, y: 7.6))
        // …folding back into the inner loop.
        path.appendArc(withCenter: NSPoint(x: x + 11, y: 7.6), radius: 2, startAngle: 0, endAngle: 180, clockwise: true)
        path.line(to: NSPoint(x: x + 9, y: 11.2))
    }

    /// `c` and `l` of the wordmark, left of the mark.
    private static func appendLetters(to path: NSBezierPath) {
        // c: open arc on the right.
        path.move(to: NSPoint(x: 8.4, y: 10.9))
        path.appendArc(withCenter: NSPoint(x: 5.6, y: 8.2), radius: 3.9, startAngle: 44, endAngle: 316, clockwise: false)
        // l: tall stem.
        path.move(to: NSPoint(x: 12.9, y: 15.8))
        path.line(to: NSPoint(x: 12.9, y: 4.5))
    }

    private static func length(of path: NSBezierPath) -> CGFloat {
        let flat = path.flattened
        var total: CGFloat = 0
        var last = NSPoint.zero
        var start = NSPoint.zero
        var pts = [NSPoint](repeating: .zero, count: 3)
        for i in 0..<flat.elementCount {
            switch flat.element(at: i, associatedPoints: &pts) {
            case .moveTo:
                last = pts[0]; start = pts[0]
            case .lineTo:
                total += hypot(pts[0].x - last.x, pts[0].y - last.y); last = pts[0]
            case .closePath:
                total += hypot(start.x - last.x, start.y - last.y); last = start
            default:
                break
            }
        }
        return total
    }
}

/// Plays a short "clip!" animation on the status-bar button whenever
/// something is copied or pasted: the clip pinches, bounces up, and its
/// stroke is redrawn from the tip.
@MainActor
final class StatusIconAnimator {
    private weak var button: NSStatusBarButton?
    private var style: ClipLogo.Style = .mark
    private var timer: Timer?
    private var start: CFTimeInterval = 0
    private let duration: CFTimeInterval = 0.7

    init(button: NSStatusBarButton?) {
        self.button = button
    }

    func setStyle(_ style: ClipLogo.Style) {
        self.style = style
        if timer == nil { button?.image = ClipLogo.image(style) }
    }

    func play() {
        guard button != nil else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Gentle fallback: a single faint→full flash.
            button?.image = ClipLogo.image(style, progress: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                self.button?.image = ClipLogo.image(self.style)
            }
            return
        }
        start = CACurrentMediaTime()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let t = min(1, (CACurrentMediaTime() - start) / duration)
        // 0–0.25: pinch; 0.15–0.6: bounce; 0.2–1: stroke redraw.
        let squeeze = t < 0.25 ? sin(t / 0.25 * .pi) : 0
        let bounceT = (t - 0.15) / 0.45
        let lift = (0...1).contains(bounceT) ? sin(bounceT * .pi) * 2.2 * (1 - bounceT * 0.4) : 0
        let drawT = max(0, (t - 0.2) / 0.8)
        let progress = 1 - pow(1 - drawT, 3) // ease-out cubic
        button?.image = ClipLogo.image(style, progress: t < 0.2 ? 1 : progress, lift: lift, squeeze: squeeze)
        if t >= 1 {
            timer?.invalidate()
            timer = nil
            button?.image = ClipLogo.image(style)
        }
    }
}
