import Foundation
import Darwin

extension ArchiveService {
    private func standaloneRunner(_ format: ArchiveFormat) throws -> ProcessRunner {
        guard let name = format.standaloneEngine else { throw ArchiveError.unsupportedFormat }
        return ProcessRunner(executable: additionalEnginesURL.appendingPathComponent(name))
    }

    func encodeStandalone(_ source: URL, destination: URL, options: CompressionOptions, control: OperationControl) throws {
        let runner = try standaloneRunner(options.format)
        let level = options.level.rawValue
        if options.format == .lrzip {
            _ = try runner.run(["-Q", "-p", "2", "-m", "2", "-w", "1", "-L", String(level), "-o", destination.path, "--", source.path], environment: ["LRZIP": "NOCONFIG", "TMP": destination.deletingLastPathComponent().path], control: control)
            return
        }
        let args: [String]
        switch options.format {
        case .lzip: args = ["-c", "-\(level)", "--", source.path]
        case .lz4: args = ["-q", "-c", "-\(level)", "--", source.path]
        case .brotli: args = ["-c", "-q", String(level), "--", source.path]
        case .snappy: args = ["-c", "--", source.path]
        default: throw ArchiveError.unsupportedFormat
        }
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ArchiveError.permissionDenied }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        _ = try runner.run(args, control: control) { data in
            do { try handle.write(contentsOf: data) }
            catch { throw (error as NSError).code == ENOSPC ? ArchiveError.diskFull : ArchiveError.permissionDenied }
        }
    }

    /// Count actual decoded bytes; streams such as Brotli do not store a size or name.
    /// The same bounded path serves preview, verification and extraction.
    func decodeStandalone(_ archive: URL, format: ArchiveFormat, control: OperationControl, output: @escaping (Data) throws -> Void) throws -> Int64 {
        let args: [String]
        switch format {
        case .lzip: args = ["-d", "-c", "--", archive.path]
        case .lz4: args = ["-d", "-q", "-c", "--", archive.path]
        case .brotli: args = ["-d", "-c", "--", archive.path]
        case .snappy: args = ["-d", "-c", "--", archive.path]
        case .lrzip: args = ["-d", "-Q", "-p", "2", "-m", "2", "-w", "1", "-o", "-", "--", archive.path]
        default: throw ArchiveError.unsupportedFormat
        }
        var total: Int64 = 0
        let scratch = format == .lrzip ? try makeStaging(in: FileManager.default.temporaryDirectory) : nil
        defer { if let scratch { StagingRegistry.remove(scratch) } }
        let environment = scratch.map { ["LRZIP": "NOCONFIG", "TMP": $0.path] } ?? [:]
        _ = try standaloneRunner(format).run(args, environment: environment, control: control) { data in
            guard Int64(data.count) <= maximumExtractedBytes - total else { throw ArchiveError.tooLarge }
            total += Int64(data.count)
            try output(data)
        }
        return total
    }
}
