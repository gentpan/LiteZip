import Foundation
import Darwin
import AppleArchive
import System

extension ArchiveService {
    func createAppleArchive(files: [URL], destination: URL, options: CompressionOptions, control: OperationControl, progress: @escaping @Sendable (ArchiveProgress) -> Void) throws -> URL {
        guard options.password?.isEmpty != false else { throw ArchiveError.unsupportedFormat }
        guard options.volumeSizeBytes == nil else { throw ArchiveError.invalidVolumeSize }
        let files = files.map(\.standardizedFileURL)
        guard Set(files).count == files.count else { throw ArchiveError.invalidInput }
        var total: Int64 = 0
        for file in files {
            guard !options.excludeMacResources || !CompressionPlanning.isMacResource(file) else { throw ArchiveError.invalidInput }
            try inspectSource(file, excludeMacResources: options.excludeMacResources, control: control, total: &total)
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard !destination.resolvingSymlinksInPath().path.hasPrefix(file.resolvingSymlinksInPath().path + "/") else { throw ArchiveError.invalidInput }
            }
        }
        let directory = destination.deletingLastPathComponent()
        guard total <= (Int64.max - 64 * 1_024 * 1_024) / 2,
              ArchiveSafety.availableBytes(at: directory) > total * 2 + 64 * 1_024 * 1_024 else { throw ArchiveError.diskFull }
        let staging = try makeStaging(in: directory)
        defer { StagingRegistry.remove(staging) }
        let inputs = staging.appendingPathComponent("inputs", isDirectory: true)
        progress(.init(totalBytes: total, currentFile: "准备 Apple 归档…"))
        try prepareSourceSnapshot(files, at: inputs, excludeMacResources: options.excludeMacResources, preserveMetadata: options.preserveMetadata, control: control)
        let partial = staging.appendingPathComponent("archive.aar")
        let algorithm = options.level == .store ? "raw" : options.level == .fastest ? "lz4" : options.level.rawValue >= 7 ? "lzma" : "lzfse"
        _ = try ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/aa")).run([
            "archive", "-d", inputs.path, "-o", partial.path, "-a", algorithm, "-t", "2"
        ], control: control)
        _ = try appleArchiveEntries(partial, control: control, verifyData: options.verifyArchive)
        try control.check()
        let result = try publish(partial, proposed: destination)
        progress(.init(fraction: 1, processedBytes: total, totalBytes: total))
        return result
    }

    func appleArchiveEntries(_ archive: URL, control: OperationControl, verifyData: Bool = false) throws -> [ArchiveEntry] {
        try walkAppleArchive(archive, control: control) { _, header, stream in
            if verifyData { try readAppleArchiveData(header, stream: stream, control: control) { _ in } }
        }
    }

    func extractAppleArchive(_ archive: URL, destination: URL, control: OperationControl, progress: @escaping @Sendable (ArchiveProgress) -> Void) throws -> URL {
        // Validate the complete path tree before creating any archived object.
        let entries = try appleArchiveEntries(archive, control: control)
        let total = try ArchiveSafety.validate(entries: entries, maximumBytes: maximumExtractedBytes)
        let directory = destination.deletingLastPathComponent()
        guard ArchiveSafety.availableBytes(at: directory) > total + 16 * 1_024 * 1_024 else { throw ArchiveError.diskFull }
        let staging = try makeStaging(in: directory)
        defer { StagingRegistry.remove(staging) }
        let content = staging.appendingPathComponent("contents", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var index = 0, processed: Int64 = 0
        let start = Date()
        _ = try walkAppleArchive(archive, control: control) { entry, header, stream in
            guard index < entries.count, entry == entries[index] else { throw ArchiveError.corruptedArchive }
            index += 1
            let target = content.appendingPathComponent(entry.path)
            if entry.isDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                guard fd >= 0 else { throw ArchiveError.permissionDenied }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                try readAppleArchiveData(header, stream: stream, control: control) { data in
                    guard Int64(data.count) <= total - processed else { throw ArchiveError.tooLarge }
                    do { try handle.write(contentsOf: data) }
                    catch { throw (error as NSError).code == ENOSPC ? ArchiveError.diskFull : ArchiveError.permissionDenied }
                    processed += Int64(data.count)
                    progress(.init(fraction: total > 0 ? Double(processed) / Double(total) : nil, processedBytes: processed, totalBytes: total, currentFile: entry.path, bytesPerSecond: Double(processed) / max(0.1, Date().timeIntervalSince(start))))
                }
            }
        }
        guard index == entries.count, processed == total else { throw ArchiveError.corruptedArchive }
        try control.check()
        let result = try publish(content, proposed: destination)
        progress(.init(fraction: 1, processedBytes: processed, totalBytes: total))
        return result
    }

    private func walkAppleArchive(_ archive: URL, control: OperationControl, body: (ArchiveEntry, ArchiveHeader, ArchiveStream) throws -> Void) throws -> [ArchiveEntry] {
        let values = try archive.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw ArchiveError.linksUnsupported }
        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: []) else { throw ArchiveError.permissionDenied }
        defer { try? file.close() }
        guard let decoded = ArchiveByteStream.decompressionStream(readingFrom: file, threadCount: 2) else { throw ArchiveError.corruptedArchive }
        defer { try? decoded.close() }
        guard let stream = ArchiveStream.decodeStream(readingFrom: decoded, threadCount: 2) else { throw ArchiveError.invalidArchive }
        defer { try? stream.close() }
        var entries = [ArchiveEntry](), total: Int64 = 0
        do {
            while let header = try stream.readHeader() {
                try control.check()
                guard let type = header.entryType else { throw ArchiveError.invalidArchive }
                if type == .metadata { continue }
                guard type == .regularFile || type == .directory else { throw ArchiveError.linksUnsupported }
                // Clone references and hard link clusters require a separate resolver.
                guard ["HLC", "CLC", "SLC"].allSatisfy({ header.field(forKey: .init($0)) == nil }) else { throw ArchiveError.linksUnsupported }
                guard case let .string(_, rawPath)? = header.field(forKey: .init("PAT")) else { throw ArchiveError.invalidArchive }
                var path = rawPath
                while path.hasPrefix("./") { path.removeFirst(2) }
                if type == .directory && (path.isEmpty || path == ".") { continue }
                if type == .directory && path.hasSuffix("/") { path.removeLast() }
                try ArchiveSafety.validate(path: path)
                var size: UInt64 = 0
                if case let .blob(_, length, _)? = header.field(forKey: .init("DAT")) { size = length }
                guard size <= UInt64(maximumExtractedBytes - total), entries.count < 200_000 else { throw ArchiveError.tooLarge }
                if type == .directory && size != 0 { throw ArchiveError.invalidArchive }
                let entry = ArchiveEntry(path: path, sourcePath: rawPath, size: Int64(size), isDirectory: type == .directory)
                entries.append(entry); total += Int64(size)
                try body(entry, header, stream)
            }
            _ = try ArchiveSafety.validate(entries: entries, maximumBytes: maximumExtractedBytes)
            return entries
        } catch let error as AppleArchive.ArchiveError {
            _ = error
            throw ArchiveError.corruptedArchive
        }
    }

    private func readAppleArchiveData(_ header: ArchiveHeader, stream: ArchiveStream, control: OperationControl, output: (Data) throws -> Void) throws {
        guard case let .blob(key, size, _)? = header.field(forKey: .init("DAT")) else { return }
        var remaining = size, buffer = [UInt8](repeating: 0, count: 65_536)
        while remaining > 0 {
            try control.check()
            let count = Int(min(remaining, UInt64(buffer.count)))
            try buffer.withUnsafeMutableBytes { bytes in
                try stream.readBlob(key: key, into: UnsafeMutableRawBufferPointer(rebasing: bytes[..<count]))
            }
            try output(Data(buffer.prefix(count)))
            remaining -= UInt64(count)
        }
    }
}
