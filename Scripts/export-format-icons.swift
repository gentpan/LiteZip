import AppKit
import Foundation

// Renders the minimal document-style format icons: a white sheet with a folded
// top-right corner, the LiteZip logo centred in a rounded tile, and the format
// label in grey beneath the sheet. Drawing them (rather than generating per-format
// artwork) keeps every format pixel-consistent and the logo exact.

struct Format: Decodable {
    let key: String
    let label: String
}

let master = 512
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fm = FileManager.default
let formats = try JSONDecoder().decode([Format].self, from: Data(contentsOf: root.appendingPathComponent("Resources/DocumentIcons/formats.json")))
guard let logo = NSImage(contentsOf: root.appendingPathComponent("Resources/Brand/litezip-logo.png")) else {
    fatalError("Missing logo: Resources/Brand/litezip-logo.png")
}

let menuDir = root.appendingPathComponent("Resources/FormatIcons")
let masterDir = root.appendingPathComponent("build/brand/format-icons")
for directory in [menuDir, masterDir] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }

func bitmap(width: Int, height: Int, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    draw(context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func writeScaled(_ image: NSImage, size: Int, to url: URL) throws {
    let rep = bitmap(width: size, height: size) { _ in
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    }
    try writePNG(rep, to: url)
}

// MARK: Geometry (y-up, master space)

let sheetLeft: CGFloat = 118
let sheetRight: CGFloat = 394
let sheetTop: CGFloat = CGFloat(master) - 20
let sheetBottom: CGFloat = CGFloat(master) - 400
let corner: CGFloat = 26
let fold: CGFloat = 66

func sheetPath() -> NSBezierPath {
    let k = corner * 0.5523
    let p = NSBezierPath()
    p.move(to: NSPoint(x: sheetLeft + corner, y: sheetTop))
    p.line(to: NSPoint(x: sheetRight - fold, y: sheetTop))
    p.line(to: NSPoint(x: sheetRight, y: sheetTop - fold))
    p.line(to: NSPoint(x: sheetRight, y: sheetBottom + corner))
    p.curve(to: NSPoint(x: sheetRight - corner, y: sheetBottom),
            controlPoint1: NSPoint(x: sheetRight, y: sheetBottom + corner - k),
            controlPoint2: NSPoint(x: sheetRight - corner + k, y: sheetBottom))
    p.line(to: NSPoint(x: sheetLeft + corner, y: sheetBottom))
    p.curve(to: NSPoint(x: sheetLeft, y: sheetBottom + corner),
            controlPoint1: NSPoint(x: sheetLeft + corner - k, y: sheetBottom),
            controlPoint2: NSPoint(x: sheetLeft, y: sheetBottom + corner - k))
    p.line(to: NSPoint(x: sheetLeft, y: sheetTop - corner))
    p.curve(to: NSPoint(x: sheetLeft + corner, y: sheetTop),
            controlPoint1: NSPoint(x: sheetLeft, y: sheetTop - corner + k),
            controlPoint2: NSPoint(x: sheetLeft + corner - k, y: sheetTop))
    p.close()
    return p
}

func superellipsePath(in rect: NSRect, exponent: CGFloat) -> NSBezierPath {
    let a = rect.width / 2, b = rect.height / 2, power = 2 / exponent
    let path = NSBezierPath()
    let steps = 160
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * .pi * 2
        let c = cos(t), s = sin(t)
        let point = NSPoint(x: rect.midX + a * pow(abs(c), power) * (c < 0 ? -1 : 1),
                            y: rect.midY + b * pow(abs(s), power) * (s < 0 ? -1 : 1))
        step == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

let sheetStroke = NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.91, alpha: 1)
let foldFill = NSColor(calibratedRed: 0.92, green: 0.94, blue: 0.96, alpha: 1)
let labelColor = NSColor(calibratedRed: 0.70, green: 0.73, blue: 0.77, alpha: 1)

func renderIcon(label: String) -> NSImage {
    let rep = bitmap(width: master, height: master) { cg in
        // Sheet with a soft drop shadow.
        cg.setShadow(offset: CGSize(width: 0, height: -3), blur: 9, color: NSColor.black.withAlphaComponent(0.10).cgColor)
        let sheet = sheetPath()
        NSColor.white.setFill()
        sheet.fill()
        cg.setShadow(offset: .zero, blur: 0, color: nil)
        sheetStroke.setStroke()
        sheet.lineWidth = 2
        sheet.stroke()

        // Folded dog-ear at the top-right.
        let flap = NSBezierPath()
        flap.move(to: NSPoint(x: sheetRight - fold, y: sheetTop))
        flap.line(to: NSPoint(x: sheetRight - fold, y: sheetTop - fold))
        flap.line(to: NSPoint(x: sheetRight, y: sheetTop - fold))
        flap.close()
        foldFill.setFill()
        flap.fill()
        sheetStroke.setStroke()
        flap.lineWidth = 2
        flap.stroke()

        // Logo tile: a white superellipse badge with the logo inset.
        let badgeSize: CGFloat = 158
        let badgeRect = NSRect(x: (sheetLeft + sheetRight) / 2 - badgeSize / 2,
                               y: 232 - badgeSize / 2,
                               width: badgeSize, height: badgeSize)
        let badge = superellipsePath(in: badgeRect, exponent: 4.6)
        cg.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: NSColor.black.withAlphaComponent(0.08).cgColor)
        NSColor.white.setFill()
        badge.fill()
        cg.setShadow(offset: .zero, blur: 0, color: nil)
        cg.saveGState()
        badge.addClip()
        logo.draw(in: badgeRect.insetBy(dx: 6, dy: 6), from: .zero, operation: .sourceOver, fraction: 1)
        cg.restoreGState()
        sheetStroke.setStroke()
        badge.lineWidth = 2
        badge.stroke()

        // Grey format label beneath the sheet.
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 46, weight: .medium),
            .foregroundColor: labelColor
        ])
        let width = text.size().width
        text.draw(at: NSPoint(x: (sheetLeft + sheetRight) / 2 - width / 2, y: sheetBottom - 62))
    }
    let image = NSImage(size: NSSize(width: master, height: master))
    image.addRepresentation(rep)
    return image
}

var rendered: [(Format, NSImage)] = []
for format in formats {
    let image = renderIcon(label: format.label)
    rendered.append((format, image))
    try writeScaled(image, size: master, to: masterDir.appendingPathComponent("Document-\(format.key).png"))
    try writeScaled(image, size: 128, to: menuDir.appendingPathComponent("Document-\(format.key).png"))
}

// Contact sheet so the whole set can be reviewed at a glance.
let columns = 5
let cell = 300
let rows = (rendered.count + columns - 1) / columns
let preview = bitmap(width: columns * cell, height: rows * cell) { _ in
    NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: columns * cell, height: rows * cell).fill()
    for (index, item) in rendered.enumerated() {
        let column = index % columns
        let row = index / columns
        let x = column * cell
        let y = rows * cell - (row + 1) * cell
        item.1.draw(in: NSRect(x: x + 30, y: y + 20, width: cell - 60, height: cell - 60), from: .zero, operation: .sourceOver, fraction: 1)
    }
}
try writePNG(preview, to: root.appendingPathComponent("build/brand/format-icons-preview.png"))
print("Rendered \(rendered.count) document-style format icons (menu 128px + masters) and a preview sheet.")
