import AppKit

/// Menu bar glyphs drawn as vectors and marked as templates, so the system tints them
/// white on a dark menu bar and black on a light one. Only alpha matters in a template.
@MainActor
enum StatusItemIcon {
    /// Full menu bar extra size; an SF Symbol at its default point size reads smaller
    /// than neighbouring extras.
    static let size = NSSize(width: 18, height: 18)

    /// The LiteZip mascot in one colour: the body with its eyes, pupils and smile, holding
    /// a stack of pages at the bottom.
    static let logo: NSImage = template { rect in
        guard let context = NSGraphicsContext.current else { return }
        NSColor.black.setFill()
        // Edge to edge: neighbouring menu bar extras measure a full 18 pt.
        NSBezierPath(roundedRect: rect, xRadius: 4.8, yRadius: 4.8).fill()

        context.compositingOperation = .destinationOut
        // Eyes look down towards the pages, like the app icon.
        NSBezierPath(ovalIn: NSRect(x: 3.3, y: 11.1, width: 3.6, height: 3.0)).fill()
        NSBezierPath(ovalIn: NSRect(x: 11.1, y: 11.1, width: 3.6, height: 3.0)).fill()
        let smile = NSBezierPath()
        smile.appendArc(withCenter: NSPoint(x: 9, y: 11.6), radius: 1.35, startAngle: 200, endAngle: 340)
        smile.lineWidth = 1.0
        smile.lineCapStyle = .round
        smile.stroke()
        // Three pages, the top one widest, held between the arms.
        for (index, page) in [(4.4, 13.6), (5.1, 12.9), (5.1, 12.9)].enumerated() {
            let y = 6.9 - CGFloat(index) * 2.45
            NSBezierPath(roundedRect: NSRect(x: page.0, y: y, width: page.1 - page.0, height: 1.75), xRadius: 0.7, yRadius: 0.7).fill()
        }

        context.compositingOperation = .sourceOver
        NSBezierPath(ovalIn: NSRect(x: 5.0, y: 11.35, width: 1.6, height: 1.6)).fill()
        NSBezierPath(ovalIn: NSRect(x: 11.4, y: 11.35, width: 1.6, height: 1.6)).fill()
    }

    /// Progress ring for unfinished jobs. A nil `fraction` draws a short arc rotated by
    /// `phase` (0–1) for work that has not reported a size yet. More than one job puts
    /// the count in the middle.
    static func ring(fraction: Double?, phase: Double, count: Int) -> NSImage {
        template { rect in
            // The stroke's outer edge meets the 18 pt canvas, matching other rings in the bar.
            let lineWidth: CGFloat = 2.4
            let circle = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let center = NSPoint(x: circle.midX, y: circle.midY)
            let track = NSBezierPath(ovalIn: circle)
            track.lineWidth = lineWidth
            NSColor.black.withAlphaComponent(0.32).setStroke()
            track.stroke()

            let start: CGFloat, sweep: CGFloat
            if let fraction {
                start = 90; sweep = 360 * CGFloat(min(1, max(0.04, fraction)))
            } else {
                start = 90 - 360 * CGFloat(phase); sweep = 100
            }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: circle.width / 2, startAngle: start, endAngle: start - sweep, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()

            guard count > 1 else { return }
            let label = count > 9 ? "9+" : "\(count)"
            let font = NSFont.monospacedDigitSystemFont(ofSize: count > 9 ? 7 : 9, weight: .bold)
            let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.black])
            let width = text.size().width
            // Centre on the digits' cap height rather than the line box.
            text.draw(at: NSPoint(x: center.x - width / 2, y: center.y - font.capHeight / 2 + font.descender))
        }
    }

    private static func template(_ draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = true
        return image
    }
}
