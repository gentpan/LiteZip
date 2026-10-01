import Foundation
import Darwin
import Testing
@testable import LiteZipCore

private let rarTestPath = ProcessInfo.processInfo.environment["LITEZIP_RAR_TEST_ENGINE"]

private struct RARFixture {
    let root: URL
    let service: ArchiveService
    init(engine: URL? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LiteZipRARTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        service = ArchiveService(engineURL: repo.appendingPathComponent("Vendor/7zip/7zz"), rarURL: engine)
    }
    func file(_ name: String, data: Data = Data("RAR 你好。".utf8)) throws -> URL {
        let result = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: result); return result
    }
    func close() { try? FileManager.default.removeItem(at: root) }
    func assertClean() throws { #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".LiteZip-") }) }
}

@Suite("Optional RAR support")
struct RARSupportTests {
    @Test("Missing RAR encoder fails clearly without staging")
    func missingEngine() async throws {
        let f = try RARFixture(); defer { f.close() }
        let file = try f.file("source.txt")
        await #expect(throws: ArchiveError.rarEngineMissing) {
            _ = try await f.service.compress(files: [file], destination: f.root.appendingPathComponent("result.rar"), options: .init(format: .rar))
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("result.rar").path))
        try f.assertClean()
    }
    @Test("RAR numbered parts preserve padding and normalize safely")
    func volumeNames() {
        for (name, first, stem) in [("data.part3.rar", "data.part1.rar", "data"), ("中文.part003.rar", "中文.part001.rar", "中文"), ("folder.v2.PART02.RAR", "folder.v2.PART01.RAR", "folder.v2")] {
            let url = URL(fileURLWithPath: "/tmp/" + name)
            #expect(ArchiveFormat.firstVolume(url)?.lastPathComponent == first)
            #expect(ArchiveFormat.detect(url) == .rar)
            #expect(ArchiveFormat.baseName(url) == stem)
        }
        for name in ["ordinary.rar", "file.part0.rar", "file.partx.rar", "file.part2.zip"] { #expect(ArchiveFormat.firstVolume(URL(fileURLWithPath: "/tmp/" + name)) == nil) }
    }
    @Test("An executable that is not official RAR is rejected")
    func engineIdentity() async throws {
        let f = try RARFixture(); defer { f.close() }
        let link = f.root.appendingPathComponent("rar")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/echo"))
        #expect(RAREngine.locate(configuredPath: link.path) == URL(fileURLWithPath: "/bin/echo").resolvingSymlinksInPath())
        #expect(RAREngine.locate(configuredPath: "/missing/rar") == nil)
        await #expect(throws: ArchiveError.invalidRAREngine) { _ = try await RAREngine.version(at: URL(fileURLWithPath: "/bin/echo")) }
    }
}

// Proprietary RAR is not fetched by CI. Run these with a locally installed engine.
@Suite("Official RAR integration", .enabled(if: rarTestPath != nil))
struct RARIntegrationTests {
    var engine: URL { URL(fileURLWithPath: rarTestPath!) }
    @Test("All compression levels, Unicode encryption and collision publishing", arguments: CompressionLevel.allCases)
    func levels(level: CompressionLevel) async throws {
        let f = try RARFixture(engine: engine); defer { f.close() }
        #expect(try await RAREngine.version(at: engine).hasPrefix("RAR "))
        let source = try f.file("中文😀.txt")
        let password = "密码🔐 mixed 123"
        let options = CompressionOptions(format: .rar, level: level, password: password)
        let target = f.root.appendingPathComponent("result.rar")
        let archive = try await f.service.compress(files: [source], destination: target, options: options)
        let entries = try await f.service.list(archive: archive, password: password)
        #expect(entries.count == 1 && entries[0].path == source.lastPathComponent && entries[0].encrypted)
        await #expect(throws: ArchiveError.wrongPassword) { _ = try await f.service.list(archive: archive) }
        await #expect(throws: ArchiveError.wrongPassword) { _ = try await f.service.extract(archive: archive, destination: f.root.appendingPathComponent("wrong"), password: "wrong") }
        let result = try await f.service.extract(archive: archive, destination: f.root.appendingPathComponent("out"), password: password)
        #expect(try Data(contentsOf: result.appendingPathComponent(source.lastPathComponent)) == Data(contentsOf: source))
        let repeated = try await f.service.compress(files: [source], destination: target, options: options)
        #expect(repeated.lastPathComponent == "result 2.rar")
        await #expect(throws: ArchiveError.rarPasswordLength) { _ = try await f.service.compress(files: [source], destination: target, options: .init(format: .rar, password: String(repeating: "x", count: 128))) }
        try f.assertClean()
    }
    @Test("Literal selection, folders, exclusions and original data stay intact", arguments: [true, false])
    func selection(exclude: Bool) async throws {
        let f = try RARFixture(engine: engine); defer { f.close() }
        let source = try f.file("literal*.txt")
        _ = try f.file("literalOTHER.txt", data: Data("must not be included".utf8))
        let at = try f.file("@list.txt"), dash = try f.file("-file.txt")
        for name in ["folder/.DS_Store", "folder/__MACOSX/meta", "folder/deep/._photo", "folder/.hidden", "folder/deep/资料😀.txt"] { _ = try f.file(name) }
        try FileManager.default.createDirectory(at: f.root.appendingPathComponent("folder/empty"), withIntermediateDirectories: true)
        let archive = try await f.service.compress(files: [source, at, dash, f.root.appendingPathComponent("folder")], destination: f.root.appendingPathComponent("selection.rar"), options: .init(format: .rar, excludeMacResources: exclude))
        let paths = Set(try await f.service.list(archive: archive).map(\.path))
        #expect(paths.contains("literal*.txt") && !paths.contains("literalOTHER.txt"))
        #expect(paths.contains("@list.txt") && paths.contains("-file.txt"))
        #expect(paths.contains("folder/.hidden") && paths.contains("folder/empty"))
        #expect(paths.contains("folder/deep/._photo") == !exclude, Comment(rawValue: paths.sorted().joined(separator: ", ")))
        #expect(paths.contains("folder/__MACOSX/meta") == !exclude)
        let out = try await f.service.extract(archive: archive, destination: f.root.appendingPathComponent("out"))
        #expect(try Data(contentsOf: out.appendingPathComponent(source.lastPathComponent)) == Data(contentsOf: source))
        #expect(try Data(contentsOf: source) == Data("RAR 你好。".utf8))
        try f.assertClean()
    }
    @Test("Encrypted RAR volumes, later part, missing and linked volumes", arguments: [3, 11])
    func volumes(count: Int) async throws {
        let f = try RARFixture(engine: engine); defer { f.close() }
        var data = Data(count: (count - 1) * 1_024 * 1_024 + 8192)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let file = try f.file("随机😀.bin", data: data)
        let password = "中文密码🔒"
        let folder = try await f.service.compress(files: [file], destination: f.root.appendingPathComponent("分卷.rar"), options: .init(format: .rar, level: .fastest, password: password, volumeSizeBytes: VolumeSize.minimum))
        let parts = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        #expect(parts.count == count)
        #expect(parts[0].lastPathComponent == (count == 3 ? "分卷.part1.rar" : "分卷.part01.rar"))
        #expect(ArchiveFormat.firstVolume(parts.last!) == parts[0])
        for part in parts { #expect(try part.resourceValues(forKeys: [.fileSizeKey]).fileSize! <= VolumeSize.minimum) }
        #expect(try await f.service.list(archive: parts.last!, password: password).count == 1)
        try await f.service.test(archive: parts[1], password: password)
        let out = try await f.service.extract(archive: parts.last!, destination: f.root.appendingPathComponent("out"), password: password)
        #expect(try Data(contentsOf: out.appendingPathComponent(file.lastPathComponent)) == data)
        try FileManager.default.removeItem(at: parts[1])
        await #expect(throws: ArchiveError.missingVolume) { _ = try await f.service.list(archive: parts[0], password: password) }
        try FileManager.default.createSymbolicLink(at: parts[1], withDestinationURL: file)
        await #expect(throws: ArchiveError.linksUnsupported) { _ = try await f.service.list(archive: parts[0], password: password) }
        try f.assertClean()
    }
    @Test("Unsafe sources and duplicate top-level names are rejected")
    func invalidSources() async throws {
        let f = try RARFixture(engine: engine); defer { f.close() }
        let first = try f.file("first/same.txt"), second = try f.file("second/same.txt")
        await #expect(throws: ArchiveError.unsafePath) { _ = try await f.service.compress(files: [first, second], destination: f.root.appendingPathComponent("dup.rar"), options: .init(format: .rar)) }
        let link = f.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        await #expect(throws: ArchiveError.linksUnsupported) { _ = try await f.service.compress(files: [link], destination: f.root.appendingPathComponent("link.rar"), options: .init(format: .rar)) }
        try f.assertClean()
    }
    @Test("Cancellation does not publish or retain a RAR snapshot")
    func cancellation() async throws {
        let f = try RARFixture(engine: engine); defer { f.close() }
        let source = try f.file("large.bin", data: Data(repeating: 0x42, count: 32 * 1_024 * 1_024))
        let control = OperationControl(), destination = f.root.appendingPathComponent("cancelled.rar")
        let task = Task { try await f.service.compress(files: [source], destination: destination, options: .init(format: .rar, level: .ultra, volumeSizeBytes: VolumeSize.minimum), control: control) }
        try await Task.sleep(for: .milliseconds(30)); control.cancel()
        await #expect(throws: ArchiveError.cancelled) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathExtension("parts").path))
        try f.assertClean()
    }
}
