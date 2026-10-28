import Foundation
import Darwin

/// The proprietary encoder is never bundled. Users select a local copy, or LiteZip
/// fetches the unmodified official package from rarlab.com when they ask for it.
public enum RAREngine {
    /// Where a downloaded package is kept: LiteZip/Engines/RAR/rar/{rar, license.txt, …}.
    public static var managedDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiteZip/Engines/RAR", isDirectory: true)
    }
    public static var managedExecutable: URL { managedDirectory.appendingPathComponent("rar/rar") }
    public static func locate(configuredPath: String? = nil) -> URL? {
        let paths = configuredPath.flatMap { $0.isEmpty ? nil : [$0] }
            ?? [managedExecutable.path, "/opt/homebrew/bin/rar", "/usr/local/bin/rar", "/opt/local/bin/rar"]
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

/// Downloads RARLAB's official macOS package and keeps it intact, licence files included.
public enum RARInstaller {
    public static let downloadPage = URL(string: "https://www.rarlab.com/download.htm")!

    public enum Architecture: Sendable {
        case arm64, x86_64
        public static var current: Architecture {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            // Also true for an Intel build running under Rosetta on Apple silicon.
            return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1 ? .arm64 : .x86_64
        }
    }

    /// Stable packages are named like rarmacos-arm-723.tar.gz; betas (730b2) are skipped.
    /// The page may list only the ARM build. Intel packages use the same version with "x64".
    public static func packageURL(inDownloadPage html: String, architecture: Architecture) -> URL? {
        guard let expression = try? NSRegularExpression(pattern: #"/rar/rarmacos-(arm64|arm|x64)-([0-9]{3,4})\.tar\.gz"#) else { return nil }
        var arm = [Int: String](), intel = [Int: String]()
        for match in expression.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let path = Range(match.range, in: html), let kind = Range(match.range(at: 1), in: html),
                  let digits = Range(match.range(at: 2), in: html), let number = Int(html[digits]) else { continue }
            if html[kind] == "x64" { intel[number] = String(html[path]) } else { arm[number] = String(html[path]) }
        }
        let path: String?
        switch architecture {
        case .arm64: path = arm.max { $0.key < $1.key }?.value
        case .x86_64: path = intel.max { $0.key < $1.key }?.value ?? arm.keys.max().map { "/rar/rarmacos-x64-\($0).tar.gz" }
        }
        return path.flatMap { URL(string: "https://www.rarlab.com" + $0) }
    }

    public static func downloadAndInstall(into directory: URL = RAREngine.managedDirectory, architecture: Architecture = .current) async throws -> (executable: URL, version: String) {
        let package: Data
        do {
            let page = try await Network.data(from: downloadPage, limit: 4 * 1_024 * 1_024)
            let html = String(decoding: page, as: UTF8.self)
            guard let url = packageURL(inDownloadPage: html, architecture: architecture) else { throw ArchiveError.rarDownloadFailed }
            package = try await Network.data(from: url, limit: 64 * 1_024 * 1_024)
        } catch let error as ArchiveError { throw error } catch { throw ArchiveError.rarDownloadFailed }
        let parent = directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let file = parent.appendingPathComponent(".rar-download-" + UUID().uuidString + ".tar.gz")
        defer { try? FileManager.default.removeItem(at: file) }
        try package.write(to: file, options: .withoutOverwriting)
        return try await install(package: file, into: directory)
    }

    /// Unpacks next to `directory`, checks the official engine, then swaps it into place.
    /// A failed check leaves any earlier copy untouched.
    public static func install(package: URL, into directory: URL) async throws -> (executable: URL, version: String) {
        let fm = FileManager.default
        let parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".rar-staging-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        // bsdtar refuses absolute paths and ".." members unless -P is given.
        try await Task.detached(priority: .utility) {
            do {
                _ = try ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/tar"))
                    .run(["-xzf", package.path, "-C", staging.path], control: OperationControl(), limit: 1_024 * 1_024)
            } catch { throw ArchiveError.invalidRAREngine }
        }.value
        let executable = staging.appendingPathComponent("rar/rar")
        let values = try? executable.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values?.isSymbolicLink == false, values?.isRegularFile == true, fm.isExecutableFile(atPath: executable.path),
              fm.fileExists(atPath: staging.appendingPathComponent("rar/license.txt").path) else { throw ArchiveError.invalidRAREngine }
        let version = try await RAREngine.version(at: executable)
        let previous = parent.appendingPathComponent(".rar-previous-" + UUID().uuidString, isDirectory: true)
        let hadPrevious = fm.fileExists(atPath: directory.path)
        if hadPrevious { try fm.moveItem(at: directory, to: previous) }
        do { try fm.moveItem(at: staging, to: directory) } catch {
            if hadPrevious { try? fm.moveItem(at: previous, to: directory) }
            throw error
        }
        if hadPrevious { try? fm.removeItem(at: previous) }
        return (directory.appendingPathComponent("rar/rar"), version)
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
