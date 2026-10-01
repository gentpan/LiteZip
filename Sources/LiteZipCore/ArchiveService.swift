import Foundation
import Darwin

public struct ArchiveService: ArchiveServiceProtocol {
    public let engineURL: URL
    public let maximumExtractedBytes: Int64
    public let zstdURL: URL
    public init(engineURL: URL, zstdURL: URL? = nil, maximumExtractedBytes: Int64 = 100 * 1_024 * 1_024 * 1_024) {
        self.engineURL = engineURL; self.zstdURL = zstdURL ?? engineURL.deletingLastPathComponent().appendingPathComponent("zstd"); self.maximumExtractedBytes = maximumExtractedBytes
    }
    public func list(archive: URL, password: String? = nil, control: OperationControl = .init()) async throws -> [ArchiveEntry] {
        try await background(control: control) { try withPreparedInput(archive, password: password, control: control) { _, entries in entries } }
    }
    private func listing(archive: URL, password: String?, control: OperationControl) throws -> [ArchiveEntry] {
        let archive = try validatedInput(archive)
        let data = try ProcessRunner(executable: engineURL).run(["l", "-slt", "-ba", "-bd", "-bse2", "-sccUTF-8", "--", archive.path], password: password, control: control)
        guard let text = String(data: data, encoding: .utf8) else { throw ArchiveError.ambiguousListing }
        let streamFormat = ArchiveFormat.detect(archive)
        let fallback = [ArchiveFormat.gzip, .bzip2, .xz, .zstd, .tarGzip].contains(streamFormat) ? ArchiveFormat.baseName(archive) : nil
        let entries = try ArchiveSafety.parseListing(text, fallbackPath: fallback)
        _ = try ArchiveSafety.validate(entries: entries, maximumBytes: maximumExtractedBytes)
        return entries
    }
    public func test(archive: URL, password: String? = nil, control: OperationControl = .init()) async throws {
        try await background(control: control) {
            try withPreparedInput(archive, password: password, control: control) { input, _ in
                _ = try ProcessRunner(executable: engineURL).run(["t", "-bd", "-bso0", "-bse2", "--", input.path], password: password, control: control)
            }
        }
    }
    public func compress(files: [URL], destination: URL, options: CompressionOptions = .init(), control: OperationControl = .init(), progress: @escaping @Sendable (ArchiveProgress) -> Void = { _ in }) async throws -> URL {
        try await background(control: control) {
            guard !files.isEmpty, options.format.canCreate else { throw ArchiveError.unsupportedFormat }
            if options.level == .store && !options.format.supportsStore { throw ArchiveError.unsupportedFormat }
            if let size = options.volumeSizeBytes {
                guard options.format.supportsVolumes, size >= VolumeSize.minimum, size <= VolumeSize.maximum else { throw ArchiveError.invalidVolumeSize }
                guard destination.lastPathComponent.lowercased().hasSuffix("." + options.format.suffix) else { throw ArchiveError.invalidInput }
            }
            if options.password?.isEmpty == false && !options.format.supportsPassword { throw ArchiveError.unsupportedFormat }
            if options.format.singleFileOnly {
                guard files.count == 1, try files[0].resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw ArchiveError.invalidInput }
            }
            if options.format == .zip, let password = options.password, (!password.unicodeScalars.allSatisfy({ $0.value < 128 }) || password.count > 99) { throw ArchiveError.zipPasswordEncoding }
            var total: Int64 = 0
            let canonicalFiles = files.map { $0.standardizedFileURL }
            guard Set(canonicalFiles).count == files.count else { throw ArchiveError.invalidInput }
            for file in canonicalFiles {
                guard !options.excludeMacResources || !CompressionPlanning.isMacResource(file) else { throw ArchiveError.invalidInput }
                try inspectSource(file, excludeMacResources: options.excludeMacResources, control: control, total: &total)
                if file.hasDirectoryPath || (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    guard !destination.resolvingSymlinksInPath().path.hasPrefix(file.resolvingSymlinksInPath().path + "/") else { throw ArchiveError.invalidInput }
                }
            }
            if let size = options.volumeSizeBytes, total / size >= 10_000 { throw ArchiveError.tooLarge }
            let directory = destination.deletingLastPathComponent()
            guard ArchiveSafety.availableBytes(at: directory) > total + 16 * 1_024 * 1_024 else { throw ArchiveError.diskFull }
            let staging = try makeStaging(in: directory)
            defer { StagingRegistry.remove(staging) }
            let volumeDirectory = staging.appendingPathComponent("volumes", isDirectory: true)
            if options.volumeSizeBytes != nil {
                try ArchiveSafety.validate(path: destination.lastPathComponent)
                try FileManager.default.createDirectory(at: volumeDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            let partial = options.volumeSizeBytes == nil ? staging.appendingPathComponent("archive." + options.format.suffix) : volumeDirectory.appendingPathComponent(destination.lastPathComponent)
            let parents = Set(canonicalFiles.map { $0.deletingLastPathComponent() })
            let workingDirectory = parents.count == 1 ? canonicalFiles[0].deletingLastPathComponent() : nil
            let paths = canonicalFiles.map { workingDirectory == nil ? $0.path : "./" + $0.lastPathComponent }
            let runner = ProcessRunner(executable: engineURL)
            let start = Date()
            var buffer = ""
            func report(_ data: Data) {
                buffer += String(decoding: data, as: UTF8.self)
                // 7-Zip emits carriage-return progress; keep only a bounded tail.
                if buffer.count > 8192 { buffer = String(buffer.suffix(4096)) }
                let tokens = buffer.components(separatedBy: CharacterSet(charactersIn: "\r\n\u{8}"))
                for token in tokens.suffix(4) {
                    let trimmed = token.trimmingCharacters(in: .whitespaces)
                    guard let percent = trimmed.firstIndex(of: "%"), let number = Double(trimmed[..<percent].trimmingCharacters(in: .whitespaces)), number >= 0, number <= 100 else { continue }
                    let fraction = number / 100
                    progress(ArchiveProgress(fraction: fraction, processedBytes: Int64(Double(total) * fraction), totalBytes: total, currentFile: String(trimmed[trimmed.index(after: percent)...]).trimmingCharacters(in: .whitespaces), bytesPerSecond: Double(total) * fraction / max(0.1, Date().timeIntervalSince(start))))
                }
            }
            progress(ArchiveProgress(totalBytes: total, currentFile: "准备压缩…"))
            var arguments = ["a", "-t" + options.format.engineType, "-mx=\(options.level.rawValue)", "-bsp1", "-bso1", "-bse2", "-bb0", "-sccUTF-8", "-spd", "-mmt=2"]
            // Explicit wildcard mode applies only to these exclusions; input names stay literal.
            let exclusions = options.excludeMacResources ? ["-xrw!.DS_Store", "-xrw!._*", "-xrw!__MACOSX"] : []
            arguments += exclusions
            if let size = options.volumeSizeBytes { arguments.append("-v\(size)b") }
            if options.format == .tar { arguments.removeAll { $0.hasPrefix("-mx=") || $0.hasPrefix("-mmt=") } }
            if let password = options.password, !password.isEmpty {
                arguments.append("-p")
                if options.format == .zip { arguments.append("-mem=AES256") }
                if options.format == .sevenZip { arguments.append("-mhe=on") }
            }
            if options.format == .zstd {
                let zstd = zstdURL
                _ = try ProcessRunner(executable: zstd).run(["-q", "-T2", "-\(options.level.rawValue)", "-o", partial.path, "--", canonicalFiles[0].path], control: control)
            } else if options.format == .tarGzip {
                let tar = staging.appendingPathComponent("payload.tar")
                _ = try runner.run(["a", "-ttar", "-bsp1", "-bse2", "-spd"] + exclusions + ["--", tar.path] + paths, directory: workingDirectory, control: control, output: report)
                _ = try runner.run(["a", "-tgzip", "-mx=\(options.level.rawValue)", "-bsp1", "-bse2", "--", partial.path, tar.path], control: control, output: report)
            } else {
                _ = try runner.run(arguments + ["--", partial.path] + paths, directory: workingDirectory, password: options.password, control: control, output: report)
            }
            try control.check()
            let readable = options.volumeSizeBytes == nil ? partial : partial.appendingPathExtension("001")
            if options.verifyArchive {
                progress(ArchiveProgress(processedBytes: total, totalBytes: total, currentFile: "正在验证完整性…"))
                _ = try runner.run(["t", "-bd", "-bso0", "-bse2", "--", readable.path], password: options.password, control: control)
            }
            try withPreparedInput(readable, password: options.password, control: control) { _, _ in () }
            try control.check()
            // Publish the complete volume set with one non-overwriting atomic rename.
            let result = options.volumeSizeBytes == nil ? try publish(partial, proposed: destination) : try publish(volumeDirectory, proposed: destination.appendingPathExtension("parts"))
            progress(ArchiveProgress(fraction: 1, processedBytes: total, totalBytes: total))
            return result
        }
    }
    public func extract(archive: URL, destination: URL, password: String? = nil, control: OperationControl = .init(), progress: @escaping @Sendable (ArchiveProgress) -> Void = { _ in }) async throws -> URL {
        try await background(control: control) {
            let fm = FileManager.default, directory = destination.deletingLastPathComponent()
            let staging = try makeStaging(in: directory)
            defer { StagingRegistry.remove(staging) }
            let content = staging.appendingPathComponent("contents", isDirectory: true)
            try fm.createDirectory(at: content, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let (input, entries) = try prepareInput(archive, staging: staging, password: password, control: control)
            let total = try ArchiveSafety.validate(entries: entries, maximumBytes: maximumExtractedBytes)
            guard ArchiveSafety.availableBytes(at: directory) > total + 16 * 1_024 * 1_024 else { throw ArchiveError.diskFull }
            let start = Date()
            var processed: Int64 = 0, lastReport = Date.distantPast
            progress(ArchiveProgress(totalBytes: total, currentFile: "准备解压…"))
            for entry in entries {
                try control.check()
                let target = content.appendingPathComponent(entry.path)
                guard target.standardizedFileURL.path.hasPrefix(content.path + "/") else { throw ArchiveError.unsafePath }
                if entry.isDirectory {
                    try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                } else {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                    try stream(archive: input, entry: entry, target: target, password: password, control: control) { count in
                        processed += Int64(count)
                        let now = Date()
                        if now.timeIntervalSince(lastReport) >= 0.1 {
                            lastReport = now
                            progress(ArchiveProgress(fraction: total > 0 ? Double(processed) / Double(total) : nil, processedBytes: processed, totalBytes: total, currentFile: entry.path, bytesPerSecond: Double(processed) / max(0.1, now.timeIntervalSince(start))))
                        }
                    }
                }
            }
            try control.check()
            let result = try publish(content, proposed: destination)
            progress(ArchiveProgress(fraction: 1, processedBytes: processed, totalBytes: total))
            return result
        }
    }
    private func isCompressedTar(_ archive: URL) -> Bool {
        let lower = archive.lastPathComponent.lowercased()
        return [".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz", ".txz", ".tar.zst"].contains(where: lower.hasSuffix)
    }
    private func prepareInput(_ archive: URL, staging: URL, password: String?, control: OperationControl) throws -> (URL, [ArchiveEntry]) {
        let input = try validatedInput(archive)
        let entries = try listing(archive: input, password: password, control: control)
        guard isCompressedTar(input) else { return (input, entries) }
        guard entries.count == 1, !entries[0].isDirectory else { throw ArchiveError.invalidArchive }
        let tar = staging.appendingPathComponent("payload.tar")
        try stream(archive: input, entry: entries[0], target: tar, password: password, control: control, onBytes: { _ in })
        return (tar, try listing(archive: tar, password: password, control: control))
    }
    private func withPreparedInput<T>(_ archive: URL, password: String?, control: OperationControl, body: (URL, [ArchiveEntry]) throws -> T) throws -> T {
        guard isCompressedTar(archive) else { return try body(validatedInput(archive), listing(archive: archive, password: password, control: control)) }
        // Browsing read-only archives must not require write access to their parent.
        let staging = try makeStaging(in: FileManager.default.temporaryDirectory)
        defer { StagingRegistry.remove(staging) }
        let (input, entries) = try prepareInput(archive, staging: staging, password: password, control: control)
        return try body(input, entries)
    }
    private func stream(archive: URL, entry: ArchiveEntry, target: URL, password: String?, control: OperationControl, onBytes: @escaping (Int) -> Void) throws {
        // The engine never receives an output directory. Only LiteZip can create files.
        let descriptor = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { throw errno == ENOSPC ? ArchiveError.diskFull : ArchiveError.permissionDenied }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var written: Int64 = 0
        let selector = entry.sourcePath.isEmpty ? [] : ["-i!" + entry.sourcePath]
        _ = try ProcessRunner(executable: engineURL).run(["x", "-so", "-bd", "-bb0", "-bso0", "-bse2", "-bsp0", "-spd"] + selector + ["--", archive.path], password: password, control: control) { data in
            guard (!entry.sizeKnown || Int64(data.count) <= entry.size - written), Int64(data.count) <= maximumExtractedBytes - written else { throw ArchiveError.tooLarge }
            do { try handle.write(contentsOf: data) }
            catch { throw (error as NSError).code == ENOSPC ? ArchiveError.diskFull : ArchiveError.permissionDenied }
            written += Int64(data.count); onBytes(data.count)
        }
        guard !entry.sizeKnown || written == entry.size else { throw ArchiveError.corruptedArchive }
    }
    private func inspectSource(_ url: URL, excludeMacResources: Bool, control: OperationControl, total: inout Int64) throws {
        try control.check()
        if excludeMacResources && CompressionPlanning.isMacResource(url) { return }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
        guard values.isSymbolicLink != true else { throw ArchiveError.linksUnsupported }
        guard !url.lastPathComponent.contains("\n"), !url.lastPathComponent.contains("\r") else { throw ArchiveError.ambiguousListing }
        if values.isDirectory == true {
            for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                try inspectSource(child, excludeMacResources: excludeMacResources, control: control, total: &total)
            }
        } else {
            guard values.isRegularFile == true else { throw ArchiveError.linksUnsupported }
            let size = Int64(values.fileSize ?? 0)
            guard total <= Int64.max - size else { throw ArchiveError.tooLarge }
            total += size
        }
    }
    private func validatedInput(_ archive: URL) throws -> URL {
        guard let first = ArchiveFormat.firstVolume(archive) else { return archive }
        let base = first.deletingPathExtension().lastPathComponent + "."
        let siblings = try FileManager.default.contentsOfDirectory(at: first.deletingLastPathComponent(), includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        var indices = Set<Int>()
        for file in siblings where file.lastPathComponent.hasPrefix(base) {
            let suffix = String(file.lastPathComponent.dropFirst(base.count))
            guard suffix.count >= 3, suffix.allSatisfy({ $0.isASCII && $0.isNumber }) else { continue }
            guard let index = Int(suffix), (1...10_000).contains(index), suffix == String(format: "%03d", index) else { throw ArchiveError.missingVolume }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw ArchiveError.linksUnsupported }
            indices.insert(index)
        }
        guard let last = indices.max(), indices.count == last, indices.contains(1) else { throw ArchiveError.missingVolume }
        return first
    }
    private func makeStaging(in directory: URL) throws -> URL {
        let result = directory.appendingPathComponent(".LiteZip-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do { try StagingRegistry.register(result) }
        catch { try? FileManager.default.removeItem(at: result); throw error }
        return result
    }
    private func publish(_ source: URL, proposed: URL) throws -> URL {
        for index in 1...10_000 {
            let candidate: URL
            if index == 1 { candidate = proposed }
            else {
                var directory: ObjCBool = false
                _ = FileManager.default.fileExists(atPath: source.path, isDirectory: &directory)
                if directory.boolValue { candidate = proposed.deletingLastPathComponent().appendingPathComponent(proposed.lastPathComponent + " \(index)") }
                else {
                    let stem = ArchiveFormat.baseName(proposed)
                    let suffix = String(proposed.lastPathComponent.dropFirst(stem.count))
                    candidate = proposed.deletingLastPathComponent().appendingPathComponent(stem + " \(index)" + suffix)
                }
            }
            if renamex_np(source.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            guard errno == EEXIST else { throw errno == ENOSPC ? ArchiveError.diskFull : ArchiveError.permissionDenied }
        }
        throw ArchiveError.invalidInput
    }
    private func background<T: Sendable>(control: OperationControl, _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread {
                    do { continuation.resume(returning: try operation()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { control.cancel() }
    }
}
