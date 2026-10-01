import AppKit
import LiteZipCore

@main
struct BadgePreview {
    @MainActor static func main() throws {
        let formats = ArchiveFormat.allCases.filter(\.canCreate)
        let height = ((formats.count + 6) / 7) * 120
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1260, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 1260, height: height).fill()
        for (index, format) in formats.enumerated() {
            let x = CGFloat(index % 7 * 180)
            let y = CGFloat(height - (index / 7 + 1) * 120)
            format.menuBadge.draw(in: NSRect(x: x + 20, y: y + 56, width: 140, height: 44), from: .zero, operation: .sourceOver, fraction: 1)
            let text = NSAttributedString(string: format.menuSummary, attributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.darkGray])
            text.draw(at: NSPoint(x: x + 90 - text.size().width / 2, y: y + 24))
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/brand/format-badges-preview.png"))
        print("Exported \(formats.count) vector format badges.")
    }
}
