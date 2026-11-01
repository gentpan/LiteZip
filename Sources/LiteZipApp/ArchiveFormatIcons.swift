import AppKit
import SwiftUI
import LiteZipCore

extension ArchiveFormat {
    /// Creation is offered only for formats people actually produce. Other single-file
    /// compressors and niche images stay extract-only in the UI; the engines keep
    /// full support, so archives in those formats still open.
    static let creatableFormats: [ArchiveFormat] = [.zip, .sevenZip, .rar, .tar, .tarGzip, .tarBzip2, .tarXZ, .tarZstd, .dmg, .iso, .lzop]
    var offersCreation: Bool { Self.creatableFormats.contains(self) }
    /// Every creatable format, by family: the format menus of the main window and the menu bar.
    static let groupedFormats: [(title: String, formats: [ArchiveFormat])] = [
        ("常用", [.zip, .sevenZip, .rar, .tarGzip]),
        ("TAR 家族", [.tar, .tarBzip2, .tarXZ, .tarZstd]),
        ("磁盘映像", [.dmg, .iso]),
        ("单个文件", [.lzop])
    ]

    /// The colour of the format's badge (see FormatBadge); every format has one.
    var badgeColor: Color {
        let hex = Self.badgeColors[self]!
        return Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    private static let badgeColors: [ArchiveFormat: UInt32] = [
        .zip: 0x1D4ED8, .sevenZip: 0x6D28D9, .rar: 0xBE123C,
        .tar: 0x475569, .tarGzip: 0x047857, .tarBzip2: 0x0E7490,
        .tarXZ: 0x4338CA, .tarZstd: 0xC2410C,
        .gzip: 0x15803D, .bzip2: 0x0369A1, .xz: 0x7E22CE,
        .zstd: 0xA16207, .dmg: 0x92400E, .zipx: 0xA21CAF,
        .lzip: 0x9D174D, .lz4: 0x365314, .brotli: 0x166534,
        .lrzip: 0x4C1D95, .aar: 0x334155, .snappy: 0xB45309,
        .wim: 0x075985, .iso: 0x52525B,
        .cab: 0x9A3412, .cpio: 0x57534E, .lzh: 0x0F766E,
        .lzma: 0x1E3A8A, .z: 0xB91C1C, .lzop: 0x854D0E
    ]

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
        case .cab: "Windows 压缩包 · 仅解压"
        case .cpio: "CPIO 归档 · 仅解压"
        case .lzh: "LHA 压缩包 · 仅解压"
        case .lzma, .z: "单个文件压缩 · 仅解压"
        case .lzop: "单个文件 · 速度极快"
        }
    }
}

/// Coloured tag naming a format. It is only as wide as its text and uses continuous
/// (superellipse) corners, like the app icon and the cards around it.
struct FormatBadge: View {
    let format: ArchiveFormat
    /// Text size in points; height, padding and corners scale with it.
    var size: CGFloat = 10
    var body: some View {
        Text(format.title)
            .font(.system(size: size, weight: .bold))
            .tracking(size * 0.03)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, size * 0.6)
            .frame(minWidth: size * 2.8, minHeight: size * 1.65)
            .background(RoundedRectangle(cornerRadius: size * 0.45, style: .continuous).fill(format.badgeColor))
            .fixedSize()
            .accessibilityHidden(true)
    }
}
