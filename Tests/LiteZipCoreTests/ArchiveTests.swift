import Foundation
import Darwin
import Testing
@testable import LiteZipCore

private struct Fixture {
    let root: URL
    let service: ArchiveService
    init(limit: Int64 = 100 * 1_024 * 1_024 * 1_024) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LiteZipTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        service = ArchiveService(engineURL: repo.appendingPathComponent("Vendor/7zip/7zz"), zstdURL: repo.appendingPathComponent("Vendor/zstd/zstd"), maximumExtractedBytes: limit)
    }
    func close() { try? FileManager.default.removeItem(at: root) }
    func makeFile(_ name: String = "中文 😀.txt", contents: Data = Data("Hello, LiteZip! 你好。".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url); return url
    }
    func input(_ name: String) -> URL { Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")! }
    func assertClean() throws {
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".LiteZip-") })
    }
}

@Suite("Archive integration")
struct ArchiveTests {
    @Test("Mac resource exclusions keep ordinary hidden and literal files", arguments: [ArchiveFormat.zip, .sevenZip, .tar, .tarGzip, .tarBzip2, .tarXZ, .tarZstd])
    func macResources(format: ArchiveFormat) async throws {
        let f = try Fixture(); defer { f.close() }
        for name in ["folder/.DS_Store", "folder/deep/.DS_Store", "folder/deep/._photo.jpg", "folder/__MACOSX/meta", "folder/.hidden", "folder/wild*.txt", "folder/deep/photo.jpg"] { _ = try f.makeFile(name) }
        let folder = f.root.appendingPathComponent("folder")
        for exclude in [true, false] {
            let archive = try await f.service.compress(files: [folder], destination: f.root.appendingPathComponent("result." + format.suffix), options: .init(format: format, excludeMacResources: exclude, verifyArchive: exclude))
            let entries = try await f.service.list(archive: archive)
            let paths = Set(entries.map(\.path))
            #expect(paths.contains("folder/.hidden"))
            #expect(paths.contains("folder/wild*.txt"))
            #expect(paths.contains("folder/deep/photo.jpg"))
            #expect(paths.contains("folder/deep/._photo.jpg") == !exclude)
            #expect(paths.contains("folder/deep/.DS_Store") == !exclude)
            #expect(paths.contains("folder/__MACOSX/meta") == !exclude)
            try await f.service.test(archive: archive)
        }
        try f.assertClean()
    }
    @Test("Compressed TAR preview and test reject unsafe inner entries", arguments: ["symlink.tar", "hardlink.tar", "fifo.tar"], [ArchiveFormat.tarGzip, .tarBzip2, .tarXZ, .tarZstd])
    func compressedTarSafety(name: String, format: ArchiveFormat) async throws {
        let f = try Fixture(); defer { f.close() }
        let archive = f.root.appendingPathComponent("unsafe." + format.suffix)
        let compression = format.tarCompression!
        if compression == .zstd {
            _ = try ProcessRunner(executable: f.service.zstdURL).run(["-q", "-o", archive.path, "--", f.input(name).path], control: .init())
        } else {
            _ = try ProcessRunner(executable: f.service.engineURL).run(["a", "-t" + compression.engineType, "-bso0", "--", archive.path, f.input(name).path], control: .init())
        }
        await #expect(throws: ArchiveError.linksUnsupported) { _ = try await f.service.list(archive: archive) }
        await #expect(throws: ArchiveError.linksUnsupported) { try await f.service.test(archive: archive) }
        try f.assertClean()
    }
    @Test("Encrypted volumes round trip, collisions, missing and linked parts", arguments: [ArchiveFormat.zip, .sevenZip])
    func volumes(format: ArchiveFormat) async throws {
        let f = try Fixture(); defer { f.close() }
        var data = Data(count: 2 * 1_024 * 1_024 + 8192)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let source = try f.makeFile("中文 😀.bin", contents: data)
        let options = CompressionOptions(format: format, level: .fastest, password: "test password", volumeSizeBytes: VolumeSize.minimum)
        let destination = f.root.appendingPathComponent("测试." + format.suffix)
        let folder = try await f.service.compress(files: [source], destination: destination, options: options)
        #expect(folder.lastPathComponent == destination.lastPathComponent + ".parts")
        let parts = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        #expect(parts.count == 3)
        for part in parts { #expect(try part.resourceValues(forKeys: [.fileSizeKey]).fileSize! <= VolumeSize.minimum) }
        #expect(ArchiveFormat.detect(parts[0]) == format)
        #expect(ArchiveFormat.baseName(parts[0]) == "测试")
        #expect(try await f.service.list(archive: parts[1], password: options.password).contains { $0.path == source.lastPathComponent })
        try await f.service.test(archive: parts[0], password: options.password)
        let result = try await f.service.extract(archive: parts[0], destination: f.root.appendingPathComponent("out"), password: options.password)
        #expect(try Data(contentsOf: result.appendingPathComponent(source.lastPathComponent)) == data)
        await #expect(throws: ArchiveError.wrongPassword) { _ = try await f.service.extract(archive: parts[0], destination: f.root.appendingPathComponent("wrong"), password: "wrong") }
        let second = try await f.service.compress(files: [source], destination: destination, options: options)
        #expect(second.lastPathComponent == folder.lastPathComponent + " 2")
        try FileManager.default.removeItem(at: parts[1])
        await #expect(throws: ArchiveError.missingVolume) { _ = try await f.service.list(archive: parts[0], password: options.password) }
        try FileManager.default.createSymbolicLink(at: parts[1], withDestinationURL: source)
        await #expect(throws: ArchiveError.linksUnsupported) { _ = try await f.service.extract(archive: parts[0], destination: f.root.appendingPathComponent("linked"), password: options.password) }
        try f.assertClean()
    }
    @Test("Volume input validation and store level", arguments: [ArchiveFormat.zip, .sevenZip])
    func volumeOptions(format: ArchiveFormat) async throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.makeFile()
        let archive = try await f.service.compress(files: [source], destination: f.root.appendingPathComponent("store." + format.suffix), options: .init(format: format, level: .store))
        try await f.service.test(archive: archive)
        await #expect(throws: ArchiveError.invalidVolumeSize) { _ = try await f.service.compress(files: [source], destination: f.root.appendingPathComponent("invalid.zip"), options: .init(volumeSizeBytes: -1)) }
        await #expect(throws: ArchiveError.invalidVolumeSize) { _ = try await f.service.compress(files: [source], destination: f.root.appendingPathComponent("invalid.tar"), options: .init(format: .tar, volumeSizeBytes: VolumeSize.minimum)) }
        #expect(try VolumeSize.parse("1.5 GB") == 1_610_612_736)
        #expect(try VolumeSize.parse("100") == 104_857_600)
        #expect(try VolumeSize.parse("  ") == nil)
        for text in ["0", "-1 MB", "1;rm", "1e9", "999999 TB", "10 KB", "NaN", "1 MB garbage"] { #expect(throws: ArchiveError.invalidVolumeSize) { try VolumeSize.parse(text) } }
        try f.assertClean()
    }
    @Test("Separate plans produce independent archives and preserve dotted folder names")
    func separate() async throws {
        let f = try Fixture(); defer { f.close() }
        let first = try f.makeFile("first.txt")
        let second = try f.makeFile("second.txt")
        _ = try f.makeFile("project.v2/child.txt")
        let output = f.root.appendingPathComponent("archives")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let plans = try CompressionPlanning.separate(files: [first, second, f.root.appendingPathComponent("project.v2")], directory: output, format: .zip)
        #expect(plans.last?.destination.lastPathComponent == "project.v2.zip")
        for plan in plans {
            let archive = try await f.service.compress(files: plan.files, destination: plan.destination)
            let entries = try await f.service.list(archive: archive)
            #expect(entries.contains { $0.path.hasPrefix(plan.files[0].lastPathComponent) })
            #expect(!entries.contains { $0.path == (plan.files[0] == first ? second : first).lastPathComponent })
        }
    }
    @Test("Unicode and zero-byte round trip", arguments: [ArchiveFormat.zip, .sevenZip, .tar, .tarGzip, .tarBzip2, .tarXZ, .tarZstd, .gzip, .bzip2, .xz, .zstd])
    func roundTrip(format: ArchiveFormat) async throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.makeFile()
        let archive = try await f.service.compress(files: [source], destination: f.root.appendingPathComponent("result." + format.suffix), options: .init(format: format))
        try await f.service.test(archive: archive)
        let result = try await f.service.extract(archive: archive, destination: f.root.appendingPathComponent("out"))
        let outputFiles = try FileManager.default.contentsOfDirectory(at: result, includingPropertiesForKeys: nil)
        #expect(outputFiles.count == 1)
        #expect(try Data(contentsOf: outputFiles[0]) == Data(contentsOf: source))
        try f.assertClean()
    }
    @Test("Nested folders, hidden files and empty files", arguments: [ArchiveFormat.zip, .sevenZip, .tar, .tarGzip, .tarBzip2, .tarXZ, .tarZstd])
    func directories(format: ArchiveFormat) async throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.makeFile("folder/deep/中文 😀.txt")
        _ = try f.makeFile("folder/.hidden", contents: Data())
        let archive = try await f.service.compress(files: [f.root.appendingPathComponent("folder")], destination: f.root.appendingPathComponent("result." + format.suffix), options: .init(format: format))
        let result = try await f.service.extract(archive: archive, destination: f.root.appendingPathComponent("out"))
        #expect(try Data(contentsOf: result.appendingPathComponent("folder/deep/中文 😀.txt")) == Data(contentsOf: source))
        #expect(FileManager.default.fileExists(atPath: result.appendingPathComponent("folder/.hidden").path))
        try f.assertClean()
    }
    @Test("AES password round trip and incorrect password", arguments: [ArchiveFormat.zip, .sevenZip])
    func encryption(format: ArchiveFormat) async throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.makeFile()
        let password = (format == .zip ? "Strong ZIP password! " : "密码🔐 ") + String(repeating: "x", count: format == .zip ? 60 : 100)
        let archive = try await f.service.compress(files: [source], destination: f.root.appendingPathComponent("secret." + format.suffix), options: .init(format: format, password: password))
        await #expect(throws: ArchiveError.wrongPassword) {
            _ = try await f.service.extract(archive: archive, destination: f.root.appendingPathComponent("wrong"), password: "incorrect")
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("wrong").path))
        let result = try await f.service.extract(archive: archive, destination: f.root.appendingPathComponent("correct"), password: password)
        #expect(try Data(contentsOf: result.appendingPathComponent(source.lastPathComponent)) == Data(contentsOf: source))
        try f.assertClean()
    }
    @Test("No overwrite on repeated output", arguments: [ArchiveFormat.zip, .tarGzip])
    func collisions(format: ArchiveFormat) async throws {
        let f = try Fixture(); defer { f.close() }
        let file = try f.makeFile()
        let desired = f.root.appendingPathComponent("archive." + format.suffix)
        let first = try await f.service.compress(files: [file], destination: desired, options: .init(format: format))
        let before = try Data(contentsOf: first)
        let second = try await f.service.compress(files: [file], destination: desired, options: .init(format: format))
        #expect(second.lastPathComponent == "archive 2." + format.suffix)
        #expect(try Data(contentsOf: first) == before)
        let out = f.root.appendingPathComponent("out")
        _ = try await f.service.extract(archive: first, destination: out)
        let out2 = try await f.service.extract(archive: second, destination: out)
        #expect(out2.lastPathComponent == "out 2")
    }
    @Test("Malicious paths rejected", arguments: ["traversal.zip", "absolute.zip", "backslash.zip", "duplicate.zip", "newline.zip"])
    func malicious(name: String) async throws {
        let f = try Fixture(); defer { f.close() }
        await #expect(throws: (any Error).self) {
            _ = try await f.service.extract(archive: f.input(name), destination: f.root.appendingPathComponent("out"))
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("out").path))
        try f.assertClean()
    }
    @Test("Links and special files rejected", arguments: ["symlink.tar", "hardlink.tar", "fifo.tar", "rar4.rar"])
    func links(name: String) async throws {
        let f = try Fixture(); defer { f.close() }
        await #expect(throws: ArchiveError.linksUnsupported) {
            _ = try await f.service.extract(archive: f.input(name), destination: f.root.appendingPathComponent("out"))
        }
        try f.assertClean()
    }
    @Test("Archive bomb preflight")
    func bomb() async throws {
        let f = try Fixture(limit: 1024); defer { f.close() }
        await #expect(throws: ArchiveError.tooLarge) {
            _ = try await f.service.extract(archive: f.input("bomb.zip"), destination: f.root.appendingPathComponent("out"))
        }
        try f.assertClean()
    }
    @Test("Empty ZIP and standard ./ TAR paths")
    func standardArchives() async throws {
        let f = try Fixture(); defer { f.close() }
        let entries = try await f.service.list(archive: f.input("empty.zip"))
        #expect(entries.isEmpty)
        let result = try await f.service.extract(archive: f.input("nested.tar"), destination: f.root.appendingPathComponent("out"))
        #expect(try String(contentsOf: result.appendingPathComponent("folder/file.txt"), encoding: .utf8) == "standard tar path")
    }
    @Test("RAR4 and RAR5 decoding", arguments: ["rar4-binary.rar", "rar5.rar"])
    func rar5(name: String) async throws {
        let f = try Fixture(); defer { f.close() }
        let entries = try await f.service.list(archive: f.input(name))
        #expect(!entries.isEmpty)
        try await f.service.test(archive: f.input(name))
        let result = try await f.service.extract(archive: f.input(name), destination: f.root.appendingPathComponent("out"))
        for entry in entries where !entry.isDirectory {
            #expect(try Data(contentsOf: result.appendingPathComponent(entry.path)).count == entry.size)
        }
    }
    @Test("Truncated archives never published")
    func truncated() async throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.makeFile()
        let archive = try await f.service.compress(files: [source], destination: f.root.appendingPathComponent("ok.zip"))
        let bytes = try Data(contentsOf: archive)
        let broken = f.root.appendingPathComponent("broken.zip")
        try bytes.prefix(bytes.count / 2).write(to: broken)
        await #expect(throws: (any Error).self) { _ = try await f.service.extract(archive: broken, destination: f.root.appendingPathComponent("out")) }
        try f.assertClean()
    }
    @Test("Cancellation cleans staged output", arguments: [false, true])
    func cancellation(volumes: Bool) async throws {
        let f = try Fixture(); defer { f.close() }
        let file = try f.makeFile("large.bin", contents: Data(repeating: 42, count: 32 * 1024 * 1024))
        let control = OperationControl(), destination = f.root.appendingPathComponent("out.7z")
        let task = Task { try await f.service.compress(files: [file], destination: destination, options: .init(format: .sevenZip, level: .ultra, volumeSizeBytes: volumes ? VolumeSize.minimum : nil), control: control) }
        try await Task.sleep(for: .milliseconds(50)); control.cancel()
        await #expect(throws: ArchiveError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("parts").path)); try f.assertClean()
    }
    @Test("ZIP Unicode password has a clear error")
    func unicodeZIP() async throws {
        let f = try Fixture(); defer { f.close() }
        let source = try f.makeFile()
        await #expect(throws: ArchiveError.zipPasswordEncoding) {
            _ = try await f.service.compress(files: [source], destination: f.root.appendingPathComponent("test.zip"), options: .init(password: "中文🔐"))
        }
    }
    @Test("Literal engine filenames", arguments: ["@input.txt", "wild*.txt", "-option.txt"])
    func literalNames(name: String) async throws {
        let f = try Fixture(); defer { f.close() }
        let file = try f.makeFile(name)
        let archive = try await f.service.compress(files: [file], destination: f.root.appendingPathComponent("result.zip"))
        let result = try await f.service.extract(archive: archive, destination: f.root.appendingPathComponent("out"))
        #expect(try Data(contentsOf: result.appendingPathComponent(name)) == Data(contentsOf: file))
    }
    @Test("1 GB streamed round trip", .enabled(if: ProcessInfo.processInfo.environment["LITEZIP_LARGE_TESTS"] == "1"))
    func largeFile() async throws {
        let f = try Fixture(); defer { f.close() }
        let file = try f.makeFile("large.bin", contents: Data())
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 1_024 * 1_024 * 1_024); try handle.close()
        let archive = try await f.service.compress(files: [file], destination: f.root.appendingPathComponent("large.zip"), options: .init(level: .fastest))
        let out = try await f.service.extract(archive: archive, destination: f.root.appendingPathComponent("out"))
        #expect(try out.appendingPathComponent("large.bin").resourceValues(forKeys: [.fileSizeKey]).fileSize == 1_024 * 1_024 * 1_024)
        try await f.service.test(archive: archive); try f.assertClean()
    }
    @Test("Engine progress arrives before exit")
    func progressDelivery() throws {
        let f = try Fixture(); defer { f.close() }
        let script = try f.makeFile("progress.sh", contents: Data("""
        #!/bin/sh
        printf '50%%\\n'
        attempts=0
        while [ ! -f "$1" ]; do
            [ "$attempts" -lt 200 ] || exit 1
            /bin/sleep 0.05
            attempts=$((attempts + 1))
        done
        printf '100%%\\n'

        """.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let acknowledgement = f.root.appendingPathComponent("received")
        var text = ""
        _ = try ProcessRunner(executable: script).run([acknowledgement.path], control: .init()) { data in
            text += String(decoding: data, as: UTF8.self)
            // The child cannot exit successfully until this callback receives its
            // tiny progress message. This proves delivery without a timing guess.
            if text.contains("50%") { try Data().write(to: acknowledgement) }
        }
        #expect(text == "50%\n100%\n")
    }
    @Test("Cross-format path checks")
    func policy() throws {
        for path in ["../../escape", "/etc/passwd", "C:/Windows/file", "a\\..\\b", "a//b", "a/./b", "x\u{0}y"] {
            #expect(throws: ArchiveError.unsafePath) { try ArchiveSafety.validate(path: path) }
        }
        try ArchiveSafety.validate(path: "中文 😀/file.txt")
        #expect(throws: ArchiveError.unsafePath) {
            _ = try ArchiveSafety.validate(entries: [.init(path: "file", size: 1), .init(path: "file/child", size: 1)], maximumBytes: 100)
        }
    }
}
