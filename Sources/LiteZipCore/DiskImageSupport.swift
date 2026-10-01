import Foundation
import Darwin

extension ArchiveService {
    private var diskImageRunner: ProcessRunner { ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/hdiutil")) }

    private func diskImagePassword(_ password: String?) throws -> Data {
        let password = password ?? ""
        guard password.utf8.count <= 4096, !password.contains("\0"), !password.contains("\n"), !password.contains("\r") else { throw ArchiveError.invalidInput }
        // hdiutil requires a NUL terminator. Never put secrets in arguments or Keychain.
        return Data(password.utf8) + Data([0])
    }

    func createDiskImage(files: [URL], destination: URL, options: CompressionOptions, control: OperationControl, progress: @escaping @Sendable (ArchiveProgress) -> Void) throws -> URL {
        guard options.volumeSizeBytes == nil else { throw ArchiveError.invalidVolumeSize }
        let secret = try diskImagePassword(options.password)
        let files = files.map(\.standardizedFileURL)
        guard Set(files).count == files.count else { throw ArchiveError.invalidInput }
        var total: Int64 = 0
        for file in files {
            guard !options.excludeMacResources || !CompressionPlanning.isMacResource(file) else { throw ArchiveError.invalidInput }
            try inspectSource(file, excludeMacResources: options.excludeMacResources, allowLinks: true, control: control, total: &total)
            if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                guard !destination.resolvingSymlinksInPath().path.hasPrefix(file.resolvingSymlinksInPath().path + "/") else { throw ArchiveError.invalidInput }
            }
        }
        // A snapshot plus an uncompressed intermediate image can coexist with output.
        let directory = destination.deletingLastPathComponent()
        guard total <= (Int64.max - 64 * 1_024 * 1_024) / 3,
              ArchiveSafety.availableBytes(at: directory) > total * 3 + 64 * 1_024 * 1_024 else { throw ArchiveError.diskFull }
        let staging = try makeStaging(in: directory)
        defer { StagingRegistry.remove(staging) }
        let inputs = staging.appendingPathComponent("inputs", isDirectory: true)
        progress(.init(totalBytes: total, currentFile: "准备磁盘映像文件快照…"))
        try prepareSourceSnapshot(files, at: inputs, excludeMacResources: options.excludeMacResources, preserveMetadata: options.preserveMetadata, allowLinks: true, control: control)
        let image = staging.appendingPathComponent("archive.dmg")
        var arguments = ["create", "-srcfolder", inputs.path, "-format", options.level == .store ? "UDRO" : "UDZO", "-fs", "HFS+", "-volname", "LiteZip", "-anyowners", "-noscrub", "-stdinpass"]
        if options.level != .store { arguments += ["-imagekey", "zlib-level=\(options.level.rawValue)"] }
        if options.password?.isEmpty == false { arguments += ["-encryption", "AES-256"] }
        progress(.init(totalBytes: total, currentFile: "正在制作 DMG…"))
        _ = try diskImageRunner.run(arguments + [image.path], standardInput: secret, control: control)
        if options.verifyArchive {
            progress(.init(processedBytes: total, totalBytes: total, currentFile: "正在验证磁盘映像…"))
            try verifyDiskImage(image, password: options.password, control: control)
        }
        // Check the actual filesystem directory even when data verification is disabled.
        _ = try diskImageEntries(image, password: options.password, control: control)
        try control.check()
        let result = try publish(image, proposed: destination)
        progress(.init(fraction: 1, processedBytes: total, totalBytes: total))
        return result
    }

    func verifyDiskImage(_ archive: URL, password: String?, control: OperationControl) throws {
        try requireRegularImage(archive)
        _ = try diskImageRunner.run(["verify", "-stdinpass", archive.path], standardInput: diskImagePassword(password), control: control)
    }

    func diskImageEntries(_ archive: URL, password: String?, control: OperationControl) throws -> [ArchiveEntry] {
        try requireRegularImage(archive)
        let staging = try makeStaging(in: FileManager.default.temporaryDirectory)
        // Staging cleanup detaches only this private mount, even after cancellation.
        defer { StagingRegistry.remove(staging) }
        let mount = staging.appendingPathComponent("volume", isDirectory: true)
        let data = try diskImageRunner.run(["attach", "-readonly", "-nobrowse", "-noautoopen", "-owners", "off", "-verify", "-noignorebadchecksums", "-mountpoint", mount.path, "-plist", "-stdinpass", archive.path], standardInput: diskImagePassword(password), control: control)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { throw ArchiveError.invalidArchive }
        let mounts = entities.compactMap { $0["mount-point"] as? String }
        guard mounts.count == 1, PrivateDiskImageMount.realPath(mounts[0]) == PrivateDiskImageMount.realPath(mount.path) else { throw ArchiveError.unsupportedFormat }
        var entries = [ArchiveEntry]()
        // These are filesystem-owned volume housekeeping, not archived user files.
        let volumeMetadata: Set<String> = [".HFS+ Private Directory Data\r", ".HFS+ Private Directory Data", ".Trashes", ".fseventsd", ".Spotlight-V100", ".DocumentRevisions-V100"]
        func walk(_ directory: URL, prefix: String) throws {
            for child in try ArchiveSafety.directoryContents(directory) {
                try control.check()
                if prefix.isEmpty && volumeMetadata.contains(child.lastPathComponent) { continue }
                let path = prefix + child.lastPathComponent
                try ArchiveSafety.validate(path: path)
                let values = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                let link = values.isSymbolicLink == true
                guard link || values.isDirectory == true || values.isRegularFile == true else { throw ArchiveError.linksUnsupported }
                guard entries.count < 200_000 else { throw ArchiveError.tooLarge }
                entries.append(.init(path: path, size: link || values.isDirectory == true ? 0 : Int64(values.fileSize ?? 0), isDirectory: !link && values.isDirectory == true, encrypted: password?.isEmpty == false, isSymbolicLink: link))
                if values.isDirectory == true && !link { try walk(child, prefix: path + "/") }
            }
        }
        try walk(mount, prefix: "")
        _ = try ArchiveSafety.validate(entries: entries, maximumBytes: maximumExtractedBytes)
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func requireRegularImage(_ archive: URL) throws {
        let values = try archive.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw ArchiveError.linksUnsupported }
    }
}

enum PrivateDiskImageMount {
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    static func mounts(inside root: URL) -> [String] {
        let rootPath = realPath(root.path)
        var filesystems: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&filesystems, MNT_NOWAIT)
        guard count > 0, let filesystems else { return [] }
        return (0..<Int(count)).compactMap { index in
            var item = filesystems[index]
            let name = withUnsafePointer(to: &item.f_mntonname) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            return name == rootPath || name.hasPrefix(rootPath + "/") ? name : nil
        }
    }
    static func detach(inside root: URL) -> Bool {
        for mount in mounts(inside: root) {
            // We only create a single volume inside an owned 0700 staging directory.
            guard mount == realPath(root.appendingPathComponent("volume").path) else { return false }
            for force in [false, true] {
                let control = OperationControl()
                let timeout = DispatchWorkItem { control.cancel() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
                defer { timeout.cancel() }
                let args = ["detach"] + (force ? ["-force"] : []) + [mount]
                if (try? ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/hdiutil")).run(args, control: control)) != nil { break }
            }
        }
        // Never recursively remove a mounted filesystem if detach failed.
        return mounts(inside: root).isEmpty
    }
}
