import AppKit
import Foundation
guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift Scripts/make-icon.swift <output.iconset> [master.png]\n", stderr)
    exit(1)
}
let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : project.appendingPathComponent("Resources/Brand/litezip-mac-icon.png")
guard let master = NSImage(contentsOf: source) else {
    fputs("Cannot read icon master: \(source.path)\n", stderr)
    exit(1)
}
let output = CommandLine.arguments[1]
let root = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16",16), ("icon_16x16@2x",32), ("icon_32x32",32), ("icon_32x32@2x",64), ("icon_128x128",128), ("icon_128x128@2x",256), ("icon_256x256",256), ("icon_256x256@2x",512), ("icon_512x512",512), ("icon_512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB,
                                  bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
                from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
}
