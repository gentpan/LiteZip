import AppKit
import Foundation
let output = CommandLine.arguments[1]
let root = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16",16), ("icon_16x16@2x",32), ("icon_32x32",32), ("icon_32x32@2x",64), ("icon_128x128",128), ("icon_128x128@2x",256), ("icon_256x256",256), ("icon_256x256@2x",512), ("icon_512x512",512), ("icon_512x512@2x",1024)] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let s = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: s); transform.concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 196, yRadius: 196)
    NSGradient(starting: NSColor(calibratedRed: 0.14, green: 0.68, blue: 0.59, alpha: 1), ending: NSColor(calibratedRed: 0.03, green: 0.36, blue: 0.37, alpha: 1))!.draw(in: background, angle: -70)
    let body = NSBezierPath(roundedRect: NSRect(x: 235, y: 245, width: 554, height: 475), xRadius: 68, yRadius: 68)
    NSColor.white.withAlphaComponent(0.94).setFill(); body.fill()
    let lid = NSBezierPath(roundedRect: NSRect(x: 203, y: 670, width: 618, height: 112), xRadius: 38, yRadius: 38)
    NSColor(calibratedWhite: 1, alpha: 1).setFill(); lid.fill()
    NSColor(calibratedRed: 0.04, green: 0.42, blue: 0.40, alpha: 1).setFill()
    for y in stride(from: 445, through: 655, by: 54) {
        NSBezierPath(roundedRect: NSRect(x: 470 + (y % 2 == 0 ? 0 : 34), y: y, width: 50, height: 34), xRadius: 6, yRadius: 6).fill()
    }
    let pull = NSBezierPath(roundedRect: NSRect(x: 453, y: 340, width: 118, height: 132), xRadius: 24, yRadius: 24); pull.fill()
    NSColor.white.setFill(); NSBezierPath(roundedRect: NSRect(x: 485, y: 373, width: 54, height: 35), xRadius: 10, yRadius: 10).fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
}
