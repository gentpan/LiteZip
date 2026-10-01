import Foundation
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
    @Test("Unicode and zero-byte round trip", arguments: [ArchiveFormat.zip, .sevenZip, .tar, .tarGzip, .gzip, .bzip2, .xz, .zstd])
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
    @Test("Nested folders, hidden files and empty files", arguments: [ArchiveFormat.zip, .sevenZip, .tar, .tarGzip])
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
    @Test("No overwrite on repeated output")
    func collisions() async throws {
        let f = try Fixture(); defer { f.close() }
        let file = try f.makeFile()
        let desired = f.root.appendingPathComponent("archive.zip")
        let first = try await f.service.compress(files: [file], destination: desired)
        let before = try Data(contentsOf: first)
        let second = try await f.service.compress(files: [file], destination: desired)
        #expect(second.lastPathComponent == "archive 2.zip")
        #expect(try Data(contentsOf: first) == before)
        let out = f.root.appendingPathComponent("out")
        _ = try await f.service.extract(archive: first, destination: out)
        let out2 = try await f.service.extract(archive: first, destination: out)
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
    @Test("Cancellation cleans staged output")
    func cancellation() async throws {
        let f = try Fixture(); defer { f.close() }
        let file = try f.makeFile("large.bin", contents: Data(repeating: 42, count: 32 * 1024 * 1024))
        let control = OperationControl(), destination = f.root.appendingPathComponent("out.7z")
        let task = Task { try await f.service.compress(files: [file], destination: destination, options: .init(format: .sevenZip, level: .ultra), control: control) }
        try await Task.sleep(for: .milliseconds(50)); control.cancel()
        await #expect(throws: ArchiveError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path)); try f.assertClean()
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
