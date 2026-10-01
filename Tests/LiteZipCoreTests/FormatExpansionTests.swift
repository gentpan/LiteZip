import Foundation
import Darwin
import Testing
@testable import LiteZipCore

private struct FormatFixture {
    let root: URL
    let service: ArchiveService
    init(limit: Int64 = 100 * 1_024 * 1_024 * 1_024) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LiteZipFormats-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        service = ArchiveService(engineURL: repo.appendingPathComponent("Vendor/7zip/7zz"), zstdURL: repo.appendingPathComponent("Vendor/zstd/zstd"), maximumExtractedBytes: limit)
    }
    func close() { try? FileManager.default.removeItem(at: root) }
    func assertClean() throws {
        #expect(PrivateDiskImageMount.mounts(inside: root).isEmpty)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".LiteZip-") })
    }
    func fixture(_ name: String) -> URL { Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")! }
}

@Suite("Additional archive formats")
struct FormatExpansionTests {
    @Test("Compressed TAR aliases keep inner paths and complete suffixes", arguments: [
        (ArchiveFormat.tarGzip, "tgz"), (.tarBzip2, "tbz"), (.tarBzip2, "tbz2"), (.tarXZ, "txz"), (.tarZstd, "tzst"), (.tarZstd, "tar.zstd")
    ])
    func tarAliases(format: ArchiveFormat, alias: String) async throws {
        let f = try FormatFixture(); defer { f.close() }
        let source = f.root.appendingPathComponent("中文.txt")
        try Data("alias".utf8).write(to: source)
        let archive = try await f.service.compress(files: [source], destination: f.root.appendingPathComponent("result." + format.suffix), options: .init(format: format))
        let renamed = f.root.appendingPathComponent("别名." + alias)
        try FileManager.default.moveItem(at: archive, to: renamed)
        #expect(ArchiveFormat.detect(renamed) == format)
        #expect(ArchiveFormat.baseName(renamed) == "别名")
        #expect(try await f.service.list(archive: renamed).map(\.path) == [source.lastPathComponent])
        let output = try await f.service.extract(archive: renamed, destination: f.root.appendingPathComponent("out"))
        #expect(try Data(contentsOf: output.appendingPathComponent(source.lastPathComponent)) == Data("alias".utf8))
        try f.assertClean()
    }
    @Test("ZIPX LZMA and BZIP2 preview, verify and extract", arguments: ["lzma.zipx", "bzip2.zipx"])
    func zipx(name: String) async throws {
        let f = try FormatFixture(); defer { f.close() }
        let input = f.fixture(name)
        #expect(ArchiveFormat.detect(input) == .zipx)
        #expect(!ArchiveFormat.zipx.canCreate)
        #expect(try await f.service.list(archive: input).count == 3)
        try await f.service.test(archive: input)
        let output = try await f.service.extract(archive: input, destination: f.root.appendingPathComponent("out"))
        #expect(try String(contentsOf: output.appendingPathComponent("中文 😀.txt"), encoding: .utf8) == "Hello ZIPX! 你好。")
        #expect(try Data(contentsOf: output.appendingPathComponent("empty")).isEmpty)
        try f.assertClean()
    }
    @Test("Unsupported ZIPX methods fail without publishing")
    func unsupportedZIPX() async throws {
        let f = try FormatFixture(); defer { f.close() }
        await #expect(throws: ArchiveError.unsupportedFormat) {
            _ = try await f.service.extract(archive: f.fixture("unsupported.zipx"), destination: f.root.appendingPathComponent("out"))
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("out").path))
        try f.assertClean()
    }
    @Test("Old ZIP spanning normalizes from every part and rejects gaps and links")
    func oldZIP() async throws {
        let f = try FormatFixture(); defer { f.close() }
        var data = Data(count: 2 * 1_024 * 1_024 + 8192)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let source = f.root.appendingPathComponent("data.bin")
        try data.write(to: source)
        _ = try ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/zip")).run(["-q", "-0", "-s", "1m", "split.zip", "data.bin"], directory: f.root, control: .init())
        let archive = f.root.appendingPathComponent("split.zip")
        let first = f.root.appendingPathComponent("split.z01"), second = f.root.appendingPathComponent("split.z02")
        for input in [archive, first, second] {
            #expect(ArchiveFormat.detect(input) == .zip)
            #expect(ArchiveFormat.firstVolume(input) == archive)
            #expect(ArchiveFormat.baseName(input) == "split")
            #expect(try await f.service.list(archive: input).map(\.path) == ["data.bin"])
            try await f.service.test(archive: input)
        }
        let output = try await f.service.extract(archive: second, destination: f.root.appendingPathComponent("out"))
        #expect(try Data(contentsOf: output.appendingPathComponent("data.bin")) == data)
        try FileManager.default.removeItem(at: first)
        await #expect(throws: ArchiveError.missingVolume) { _ = try await f.service.list(archive: second) }
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: source)
        await #expect(throws: ArchiveError.linksUnsupported) { _ = try await f.service.list(archive: second) }
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: archive)
        await #expect(throws: ArchiveError.missingVolume) { _ = try await f.service.list(archive: second) }
        try f.assertClean()
    }
    @Test("Old RAR volumes extract and reject missing or linked parts")
    func oldRAR() async throws {
        let f = try FormatFixture(); defer { f.close() }
        for ext in ["rar", "r00", "r01"] { try FileManager.default.copyItem(at: f.fixture("legacy." + ext), to: f.root.appendingPathComponent("legacy." + ext)) }
        let archive = f.root.appendingPathComponent("legacy.rar"), next = f.root.appendingPathComponent("legacy.r00"), last = f.root.appendingPathComponent("legacy.r01")
        for input in [archive, next, last] {
            #expect(ArchiveFormat.detect(input) == .rar)
            #expect(ArchiveFormat.firstVolume(input) == archive)
            #expect(ArchiveFormat.baseName(input) == "legacy")
            try await f.service.test(archive: input)
            #expect(try await f.service.list(archive: input).first?.size == 20111)
        }
        let output = try await f.service.extract(archive: last, destination: f.root.appendingPathComponent("out"))
        let bytes = try Data(contentsOf: output.appendingPathComponent("LibarchiveAddingTest.html"))
        #expect(bytes.count == 20111)
        try FileManager.default.removeItem(at: next)
        await #expect(throws: ArchiveError.missingVolume) { _ = try await f.service.list(archive: last) }
        try FileManager.default.createSymbolicLink(at: next, withDestinationURL: f.fixture("legacy.r00"))
        await #expect(throws: ArchiveError.linksUnsupported) { _ = try await f.service.list(archive: archive) }
        try f.assertClean()
    }
}

@Suite("Native disk images", .serialized)
struct DiskImageTests {
    @Test("DMG preserves bundle metadata and links; encrypted and stored images", arguments: [false, true])
    func images(encrypted: Bool) async throws {
        let f = try FormatFixture(); defer { f.close() }
        let folder = f.root.appendingPathComponent("测试.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let executable = folder.appendingPathComponent("tool")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let attribute = Data("metadata".utf8)
        #expect(attribute.withUnsafeBytes { setxattr(executable.path, "com.litezip.test", $0.baseAddress, $0.count, 0, 0) } == 0)
        #expect(attribute.withUnsafeBytes { setxattr(executable.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) } == 0)
        let app = f.root.appendingPathComponent("测试.app")
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("external").path, withDestinationPath: "/Applications")
        try Data("resource".utf8).write(to: app.appendingPathComponent(".DS_Store"))
        let password = encrypted ? "中文 🔒 image" : nil
        let options = CompressionOptions(format: .dmg, level: encrypted ? .normal : .store, password: password, excludeMacResources: encrypted)
        let destination = f.root.appendingPathComponent("result.dmg")
        let image = try await f.service.compress(files: [app], destination: destination, options: options)
        #expect(ArchiveFormat.detect(image) == .dmg)
        let entries = try await f.service.list(archive: image, password: password)
        #expect(entries.contains { $0.path == "测试.app/external" && $0.isSymbolicLink })
        #expect(!entries.contains { $0.path.hasPrefix("测试.app/external/") })
        #expect(entries.contains { $0.path == "测试.app/.DS_Store" } == !encrypted)
        try await f.service.test(archive: image, password: password)
        if encrypted {
            await #expect(throws: ArchiveError.wrongPassword) { _ = try await f.service.list(archive: image, password: "wrong") }
            await #expect(throws: ArchiveError.wrongPassword) { try await f.service.test(archive: image) }
        }
        // Inspect the mounted filesystem without executing the archived executable.
        let staging = try f.service.makeStaging(in: f.root)
        let mount = staging.appendingPathComponent("volume")
        defer { StagingRegistry.remove(staging) }
        _ = try ProcessRunner(executable: URL(fileURLWithPath: "/usr/bin/hdiutil")).run(["attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, "-stdinpass", image.path], standardInput: Data((password ?? "").utf8) + Data([0]), control: .init())
        let mountedFile = mount.appendingPathComponent("测试.app/Contents/MacOS/tool")
        #expect(try FileManager.default.attributesOfItem(atPath: mountedFile.path)[.posixPermissions] as? Int == 0o755)
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBytes { getxattr(mountedFile.path, "com.litezip.test", $0.baseAddress, $0.count, 0, 0) }
        #expect(count == attribute.count)
        #expect(Data(buffer.prefix(max(0, count))) == attribute)
        let forkCount = buffer.withUnsafeMutableBytes { getxattr(mountedFile.path, "com.apple.ResourceFork", $0.baseAddress, $0.count, 0, 0) }
        #expect(forkCount == attribute.count)
        #expect(Data(buffer.prefix(max(0, forkCount))) == attribute)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: mount.appendingPathComponent("测试.app/external").path) == "/Applications")
        StagingRegistry.remove(staging)
        let repeated = try await f.service.compress(files: [app], destination: destination, options: options)
        #expect(repeated.lastPathComponent == "result 2.dmg")
        await #expect(throws: ArchiveError.diskImageMountRequired) { _ = try await f.service.extract(archive: image, destination: f.root.appendingPathComponent("out"), password: password) }
        try f.assertClean()
    }
    @Test("DMG rejects invalid options, duplicate roots and cancelled work")
    func validation() async throws {
        let f = try FormatFixture(); defer { f.close() }
        let file = f.root.appendingPathComponent("source")
        try Data("data".utf8).write(to: file)
        let destination = f.root.appendingPathComponent("invalid.dmg")
        await #expect(throws: ArchiveError.invalidVolumeSize) { _ = try await f.service.compress(files: [file], destination: destination, options: .init(format: .dmg, volumeSizeBytes: VolumeSize.minimum)) }
        await #expect(throws: ArchiveError.invalidInput) { _ = try await f.service.compress(files: [file], destination: destination, options: .init(format: .dmg, password: "bad\0password")) }
        let directory = f.root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let other = directory.appendingPathComponent("source")
        try Data().write(to: other)
        await #expect(throws: ArchiveError.unsafePath) { _ = try await f.service.compress(files: [file, other], destination: destination, options: .init(format: .dmg)) }
        let control = OperationControl(); control.cancel()
        await #expect(throws: ArchiveError.cancelled) { _ = try await f.service.compress(files: [file], destination: destination, options: .init(format: .dmg), control: control) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        try f.assertClean()
    }
}
