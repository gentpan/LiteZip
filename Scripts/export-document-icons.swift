import AppKit
import Foundation

struct Format: Decodable {
    let key: String
    let label: String
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fm = FileManager.default
let formats = try JSONDecoder().decode([Format].self, from: Data(contentsOf: root.appendingPathComponent("Resources/DocumentIcons/formats.json")))
let artwork = root.appendingPathComponent("Resources/DocumentIcons")
let documents = root.appendingPathComponent("Resources/DocumentTypes")
let exports = root.appendingPathComponent("build/brand/document-icons")
for directory in [documents, exports] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }

func bitmap(width: Int, height: Int, draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ image: NSImage, size: Int, to url: URL) throws {
    let rep = bitmap(width: size, height: size) {
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
    }
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

var images: [(Format, NSImage)] = []
let existingOnly = CommandLine.arguments.contains("--existing-only")
for format in formats {
    let source = artwork.appendingPathComponent("Sources/\(format.key).png")
    guard let image = NSImage(contentsOf: source) else {
        if existingOnly { continue }
        fatalError("Missing generated source: \(source.path)")
    }
    images.append((format, image))
    try writePNG(image, size: 1024, to: artwork.appendingPathComponent("Document-\(format.key).png"))
    let iconset = exports.appendingPathComponent("Document-\(format.key).iconset")
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        try writePNG(image, size: size, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
        try writePNG(image, size: size * 2, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", documents.appendingPathComponent("Document-\(format.key).icns").path]
    try process.run(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("iconutil failed: \(format.label)") }
}

let sheet = bitmap(width: 1500, height: 1080) {
    NSColor(calibratedRed: 0.93, green: 0.96, blue: 1, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 1500, height: 1080).fill()
    for (index, item) in images.enumerated() {
        let x = (index % 5) * 300
        let y = 1080 - (index / 5 + 1) * 360
        item.1.draw(in: NSRect(x: x + 20, y: y + 75, width: 260, height: 260), from: .zero, operation: .sourceOver, fraction: 1)
        let text = NSAttributedString(string: item.0.label, attributes: [.font: NSFont.systemFont(ofSize: 21, weight: .medium), .foregroundColor: NSColor(calibratedRed: 0.06, green: 0.16, blue: 0.3, alpha: 1)])
        text.draw(at: NSPoint(x: CGFloat(x + 150) - text.size().width / 2, y: CGFloat(y + 32)))
    }
}
try sheet.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("build/brand/document-icons-preview.png"))
print("Exported \(images.count) branded document PNGs and Finder ICNS.")
