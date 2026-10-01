import Foundation

extension ArchiveService {
    func createISO(files: [URL], destination: URL, options: CompressionOptions, control: OperationControl, progress: @escaping @Sendable (ArchiveProgress) -> Void) throws -> URL {
        guard options.volumeSizeBytes == nil else { throw ArchiveError.invalidVolumeSize }
        guard options.password?.isEmpty != false else { throw ArchiveError.unsupportedFormat }
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
        progress(.init(totalBytes: total, currentFile: "准备光盘映像文件快照…"))
        try prepareSourceSnapshot(files, at: inputs, excludeMacResources: options.excludeMacResources, control: control)
        let image = staging.appendingPathComponent("archive.iso")
        progress(.init(totalBytes: total, currentFile: "正在制作 ISO…"))
        _ = try ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/hdiutil")).run([
            "makehybrid", "-iso", "-joliet", "-udf", "-default-volume-name", "LiteZip", "-o", image.path, inputs.path
        ], control: control)
        let engine = ProcessRunner(executable: engineURL)
        let data = try engine.run(["l", "-slt", "-ba", "-bd", "-sccUTF-8", "--", image.path], control: control)
        guard let listing = String(data: data, encoding: .utf8) else { throw ArchiveError.ambiguousListing }
        _ = try ArchiveSafety.validate(entries: ArchiveSafety.parseListing(listing), maximumBytes: maximumExtractedBytes)
        if options.verifyArchive {
            progress(.init(processedBytes: total, totalBytes: total, currentFile: "正在验证 ISO…"))
            _ = try engine.run(["t", "-bd", "-bso0", "-bse2", "--", image.path], control: control)
        }
        try control.check()
        let result = try publish(image, proposed: destination)
        progress(.init(fraction: 1, processedBytes: total, totalBytes: total))
        return result
    }
}
