import AppKit
import LiteZipCore

extension ArchiveFormat {
    @MainActor var menuBadge: NSImage { ArchiveBadgeCache.images[rawValue]! }

    var menuSummary: String {
        switch self {
        case .zip: "通用压缩"
        case .sevenZip: "高压缩"
        case .rar: "官方压缩引擎"
        case .tar: "仅打包，不压缩"
        case .tarGzip: "打包 + GZIP"
        case .tarBzip2: "打包 + BZIP2"
        case .tarXZ: "打包 + XZ"
        case .tarZstd: "打包 + ZSTD"
        case .gzip, .bzip2, .xz, .zstd, .lzip, .lz4, .brotli, .lrzip, .snappy: "单个文件压缩"
        case .aar: "Apple 归档"
        case .wim: "Windows 映像"
        case .iso: "光盘映像 · 不压缩"
        case .dmg: "磁盘映像"
        case .zipx: "仅解压"
        }
    }
}

@MainActor
private enum ArchiveBadgeCache {
    /// Vector artwork retains full-size text instead of shrinking a document icon.
    static let images: [String: NSImage] = Dictionary(uniqueKeysWithValues: ArchiveFormat.allCases.map { format in
        let colors: [ArchiveFormat: UInt32] = [
            .zip: 0x1D4ED8, .sevenZip: 0x6D28D9, .rar: 0xBE123C,
            .tar: 0x475569, .tarGzip: 0x047857, .tarBzip2: 0x0E7490,
            .tarXZ: 0x4338CA, .tarZstd: 0xC2410C,
            .gzip: 0x15803D, .bzip2: 0x0369A1, .xz: 0x7E22CE,
            .zstd: 0xA16207, .dmg: 0x92400E, .zipx: 0xA21CAF,
            .lzip: 0x9D174D, .lz4: 0x365314, .brotli: 0x166534,
            .lrzip: 0x4C1D95, .aar: 0x334155, .snappy: 0xB45309,
            .wim: 0x075985, .iso: 0x52525B
        ]
        let hex = colors[format]!
        let color = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                            green: CGFloat((hex >> 8) & 255) / 255,
                            blue: CGFloat(hex & 255) / 255, alpha: 1)
        let image = NSImage(size: NSSize(width: 70, height: 22), flipped: false) { bounds in
            color.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
            let text = NSAttributedString(string: format.title, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: NSColor.white
            ])
            text.draw(at: NSPoint(x: (bounds.width - text.size().width) / 2,
                                  y: (bounds.height - text.size().height) / 2))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = format.title
        return (format.rawValue, image)
    })
}
