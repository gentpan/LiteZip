import Foundation

public enum ArchiveFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case zip, sevenZip, tar, tarGzip, gzip, bzip2, xz, zstd, rar
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .sevenZip: "7Z"
        case .tarGzip: "TAR.GZ"
        default: rawValue.uppercased()
        }
    }
    public var suffix: String {
        switch self { case .sevenZip: "7z"; case .tarGzip: "tar.gz"; case .gzip: "gz"; case .bzip2: "bz2"; case .zstd: "zst"; default: rawValue }
    }
    public var engineType: String { self == .sevenZip ? "7z" : rawValue }
    public var canCreate: Bool { self != .rar }
    public var supportsPassword: Bool { [.zip, .sevenZip, .rar].contains(self) }
    public var singleFileOnly: Bool { [.gzip, .bzip2, .xz, .zstd].contains(self) }
    public static func detect(_ url: URL) -> ArchiveFormat? {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return nil }
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGzip }
        let ext = url.pathExtension.lowercased()
        let extensions: [String: ArchiveFormat] = ["zip": .zip, "7z": .sevenZip, "rar": .rar, "tar": .tar, "gz": .gzip, "bz2": .bzip2, "xz": .xz, "zst": .zstd, "zstd": .zstd]
        if let format = extensions[ext] { return format }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 8) else { return nil }
        let bytes = Array(data)
        if bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]) || bytes.starts(with: [0x50, 0x4b, 0x05, 0x06]) { return .zip }
        if bytes.starts(with: [0x37, 0x7a, 0xbc, 0xaf, 0x27, 0x1c]) { return .sevenZip }
        if bytes.starts(with: [0x52, 0x61, 0x72, 0x21, 0x1a, 0x07]) { return .rar }
        if bytes.starts(with: [0x1f, 0x8b]) { return .gzip }
        if bytes.starts(with: [0x42, 0x5a, 0x68]) { return .bzip2 }
        if bytes.starts(with: [0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00]) { return .xz }
        if bytes.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) { return .zstd }
        return nil
    }
    public static func baseName(_ url: URL) -> String {
        let name = url.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tgz", ".tbz2", ".txz"] {
            if name.lowercased().hasSuffix(suffix) { return String(name.dropLast(suffix.count)) }
        }
        return url.deletingPathExtension().lastPathComponent
    }
}

public enum CompressionLevel: Int, CaseIterable, Sendable, Identifiable {
    case fastest = 1, fast = 3, normal = 5, maximum = 7, ultra = 9
    public var id: Int { rawValue }
    public var title: String {
        switch self { case .fastest: "最快"; case .fast: "快速"; case .normal: "标准"; case .maximum: "高压缩"; case .ultra: "极限" }
    }
}

public struct CompressionOptions: Sendable {
    public var format: ArchiveFormat
    public var level: CompressionLevel
    public var password: String?
    public var preserveMetadata: Bool
    public init(format: ArchiveFormat = .zip, level: CompressionLevel = .normal, password: String? = nil, preserveMetadata: Bool = true) {
        self.format = format; self.level = level; self.password = password; self.preserveMetadata = preserveMetadata
    }
}

public struct ArchiveEntry: Sendable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    public let sourcePath: String
    public let size: Int64
    public let sizeKnown: Bool
    public let isDirectory: Bool
    public let encrypted: Bool
    public init(path: String, sourcePath: String? = nil, size: Int64, sizeKnown: Bool = true, isDirectory: Bool = false, encrypted: Bool = false) {
        self.path = path; self.sourcePath = sourcePath ?? path; self.size = size; self.sizeKnown = sizeKnown; self.isDirectory = isDirectory; self.encrypted = encrypted
    }
}

public struct ArchiveProgress: Sendable {
    public let fraction: Double?
    public let processedBytes: Int64
    public let totalBytes: Int64
    public let currentFile: String
    public let bytesPerSecond: Double
    public var remainingSeconds: Double? {
        bytesPerSecond > 0 && totalBytes > processedBytes ? Double(totalBytes - processedBytes) / bytesPerSecond : nil
    }
    public init(fraction: Double? = nil, processedBytes: Int64 = 0, totalBytes: Int64 = 0, currentFile: String = "", bytesPerSecond: Double = 0) {
        self.fraction = fraction; self.processedBytes = processedBytes; self.totalBytes = totalBytes; self.currentFile = currentFile; self.bytesPerSecond = bytesPerSecond
    }
}

public enum ArchiveError: Error, LocalizedError, Sendable, Equatable {
    case invalidArchive, corruptedArchive, wrongPassword, unsupportedFormat, missingVolume, diskFull, permissionDenied, cancelled
    case unsafePath, linksUnsupported, tooLarge, ambiguousListing, invalidInput, engineMissing, zipPasswordEncoding
    public var errorDescription: String? {
        switch self {
        case .invalidArchive: "这个文件不是有效的压缩包，或文件头已损坏。"
        case .corruptedArchive: "压缩包不完整或校验失败，请重新获取文件。"
        case .wrongPassword: "需要密码，或密码不正确。请输入密码后重试。"
        case .unsupportedFormat: "暂不支持这个格式或压缩方式。"
        case .missingVolume: "缺少后续分卷，请把所有分卷放在同一文件夹。"
        case .diskFull: "可用磁盘空间不足，请释放空间或选择其他位置。"
        case .permissionDenied: "无法访问这个位置，请选择可读写的文件夹。"
        case .cancelled: "任务已取消，未完成的文件已清理。"
        case .unsafePath: "压缩包包含越界路径、重复路径或不安全文件名，已停止解压。"
        case .linksUnsupported: "基础版本暂不处理符号链接、硬链接或特殊文件，请先移除链接。"
        case .tooLarge: "预计展开大小超过安全限制（默认 100 GB），请检查压缩包或调整设置。"
        case .ambiguousListing: "文件名包含无法安全解析的换行或元数据，已停止处理。"
        case .invalidInput: "请选择有效的文件；单文件压缩格式只能处理一个普通文件。"
        case .zipPasswordEncoding: "ZIP 加密支持不超过 99 个 ASCII 字符（英文、数字和符号）。中文、Emoji 或更长密码请选择 7Z。"
        case .engineMissing: "内置压缩引擎缺失，请重新安装 LiteZip。"
        }
    }
}

public protocol ArchiveServiceProtocol: Sendable {
    func compress(files: [URL], destination: URL, options: CompressionOptions, control: OperationControl, progress: @escaping @Sendable (ArchiveProgress) -> Void) async throws -> URL
    func extract(archive: URL, destination: URL, password: String?, control: OperationControl, progress: @escaping @Sendable (ArchiveProgress) -> Void) async throws -> URL
    func list(archive: URL, password: String?, control: OperationControl) async throws -> [ArchiveEntry]
    func test(archive: URL, password: String?, control: OperationControl) async throws
}
