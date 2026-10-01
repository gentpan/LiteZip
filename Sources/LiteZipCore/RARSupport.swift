import Foundation
import Darwin

/// The proprietary encoder is selected locally, never bundled or downloaded by the app.
public enum RAREngine {
    public static func locate(configuredPath: String? = nil) -> URL? {
        let paths = configuredPath.flatMap { $0.isEmpty ? nil : [$0] }
            ?? ["/opt/homebrew/bin/rar", "/usr/local/bin/rar", "/opt/local/bin/rar"]
        return paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
    public static func version(at url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let control = OperationControl()
            let timeout = Task {
                try? await Task.sleep(for: .seconds(10))
                if !Task.isCancelled { control.cancel() }
            }
            defer { timeout.cancel() }
            let data = try ProcessRunner(executable: url).run(["-cfg-"], control: control, limit: 64 * 1_024)
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            guard let header = lines.first(where: { $0.hasPrefix("RAR ") }),
                  header.contains("Alexander Roshal"),
                  let version = header.split(separator: " ").dropFirst().first,
                  let major = Int(version.split(separator: ".").first ?? ""), major >= 7 else { throw ArchiveError.invalidRAREngine }
            return "RAR " + version
        }.value
    }
}

struct RARVolume {
    let url: URL
    let stem: String
    let prefix: String
    let extensionName: String
    let index: Int
    let width: Int
    init?(_ url: URL) {
        guard url.pathExtension.lowercased() == "rar" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard let range = name.range(of: ".part", options: [.backwards, .caseInsensitive]) else { return nil }
        let digits = String(name[range.upperBound...])
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits), number > 0 else { return nil }
        self.url = url; stem = String(name[..<range.lowerBound]); prefix = String(name[..<range.upperBound])
        extensionName = url.pathExtension; index = number
        var padding = digits.first == "0" ? digits.count : 1
        // part10 can belong to either part1 or part01. Look for the actual first
        // volume instead of discarding padding when a later index fills its width.
        if padding == 1 && digits.count > 1 {
            for candidate in 1...digits.count {
                let first = url.deletingLastPathComponent().appendingPathComponent(prefix + String(format: "%0*d", candidate, 1) + "." + extensionName)
                if FileManager.default.fileExists(atPath: first.path) { padding = candidate; break }
            }
        }
        width = padding
    }
    var canonicalName: String { prefix + String(format: "%0*d", width, index) + "." + extensionName }
    var firstURL: URL { url.deletingLastPathComponent().appendingPathComponent(prefix + String(format: "%0*d", width, 1) + "." + extensionName) }
}

extension ArchiveService {
    /// RAR expands wildcards even in an argument list. Archive an isolated snapshot
    /// using a constant "." operand, so source names are always treated literally.
    func prepareSourceSnapshot(_ files: [URL], at root: URL, excludeMacResources: Bool, preserveMetadata: Bool = false, allowLinks: Bool = false, control: OperationControl) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var names = Set<String>()
        for source in files {
            let name = source.lastPathComponent
            try ArchiveSafety.validate(path: name)
            guard names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw ArchiveError.unsafePath }
            try snapshot(source, to: root.appendingPathComponent(name), excludeMacResources: excludeMacResources, preserveMetadata: preserveMetadata, allowLinks: allowLinks, control: control)
        }
    }
    private func snapshot(_ source: URL, to target: URL, excludeMacResources: Bool, preserveMetadata: Bool, allowLinks: Bool, control: OperationControl) throws {
        try control.check()
        if excludeMacResources && CompressionPlanning.isMacResource(source) { return }
        try ArchiveSafety.validate(path: source.lastPathComponent)
        let fm = FileManager.default
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey])
        if values.isSymbolicLink == true {
            guard allowLinks else { throw ArchiveError.linksUnsupported }
            // Preserve the link text without resolving or reading its target.
            try fm.createSymbolicLink(atPath: target.path, withDestinationPath: fm.destinationOfSymbolicLink(atPath: source.path))
            return
        } else if values.isDirectory == true {
            try fm.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            for child in try ArchiveSafety.directoryContents(source) {
                try snapshot(child, to: target.appendingPathComponent(child.lastPathComponent), excludeMacResources: excludeMacResources, preserveMetadata: preserveMetadata, allowLinks: allowLinks, control: control)
            }
        } else {
            guard values.isRegularFile == true else { throw ArchiveError.linksUnsupported }
            // APFS clones avoid duplicating file data. Other filesystems use bounded,
            // cancellable copying. CLONE_NOFOLLOW must never resolve a changed link.
            if clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) != 0 {
                let input = open(source.path, O_RDONLY | O_NOFOLLOW)
                guard input >= 0 else { throw ArchiveError.permissionDenied }
                let reader = FileHandle(fileDescriptor: input, closeOnDealloc: true)
                defer { try? reader.close() }
                var info = stat()
                guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ArchiveError.linksUnsupported }
                let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard output >= 0 else { throw errno == ENOSPC ? ArchiveError.diskFull : ArchiveError.permissionDenied }
                let writer = FileHandle(fileDescriptor: output, closeOnDealloc: true)
                defer { try? writer.close() }
                while let data = try reader.read(upToCount: 65_536), !data.isEmpty {
                    try control.check(); try writer.write(contentsOf: data)
                }
            }
            let copied = try target.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard copied.isSymbolicLink != true, copied.isRegularFile == true else { throw ArchiveError.linksUnsupported }
            if !preserveMetadata { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path) }
            if let date = values.contentModificationDate { try fm.setAttributes([.modificationDate: date], ofItemAtPath: target.path) }
        }
        if preserveMetadata {
            let flags = copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW_SRC | COPYFILE_NOFOLLOW_DST)
            guard copyfile(source.path, target.path, nil, flags) == 0 else { throw ArchiveError.permissionDenied }
        }
        try control.check()
    }
}
