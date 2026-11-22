import AppKit

/// Menu bar glyph: the CX monogram from the app icon, drawn as a template image so macOS tints it
/// for light and dark menu bars. Geometry uses the app icon's 1024-point design space
/// (see `scripts/make-icon.swift`), scaled to fit an 18 × 18 pt status item.
@MainActor
enum MenuBarIcon {
    enum State { case running, stopped, busy }

    private static let running = make(.running)
    private static let stopped = make(.stopped)
    private static let busy = make(.busy)

    static func image(for state: State) -> NSImage {
        switch state {
        case .running: running
        case .stopped: stopped
        case .busy: busy
        }
    }

    static func make(_ state: State) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // Glyph bounds in design space, stroke caps and status dot included: x 223…882, y 236…812.
            let (minX, maxX, minY, maxY): (CGFloat, CGFloat, CGFloat, CGFloat) = (223, 882, 236, 812)
            let scale = 17 / max(maxX - minX, maxY - minY)
            let originX = (18 - (maxX - minX) * scale) / 2
            let originY = (18 - (maxY - minY) * scale) / 2
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: originX + (x - minX) * scale, y: originY + (y - minY) * scale)
            }

            // A stopped VM is drawn faded: template images keep their alpha.
            let ink = NSColor.black.withAlphaComponent(state == .stopped ? 0.45 : 1)
            ink.set()

            // C: radius 230 around (499.4, 512), open to the right between ±52.3°.
            let c = NSBezierPath()
            c.appendArc(withCenter: point(499.4, 512), radius: 230 * scale, startAngle: 52.3, endAngle: -52.3, clockwise: false)
            c.lineWidth = 92 * scale
            c.lineCapStyle = .round
            c.stroke()

            // X inside the opening of the C.
            let x = NSBezierPath()
            x.move(to: point(560, 420)); x.line(to: point(760, 620))
            x.move(to: point(760, 420)); x.line(to: point(560, 620))
            x.lineWidth = 78 * scale
            x.lineCapStyle = .round
            x.stroke()

            // Status dot at the top-right corner, outside the X: center (830, 760), radius 52.
            // Filled while running, a ring while an operation is in progress, absent when stopped.
            let dotRect = NSRect(origin: point(778, 708), size: NSSize(width: 104 * scale, height: 104 * scale))
            switch state {
            case .running:
                NSBezierPath(ovalIn: dotRect).fill()
            case .busy:
                let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: 0.5, dy: 0.5))
                ring.lineWidth = 1
                ring.stroke()
            case .stopped:
                break
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ColimaX"
        return image
    }
}
