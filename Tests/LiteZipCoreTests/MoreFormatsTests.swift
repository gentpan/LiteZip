import Foundation
import Darwin
import Testing
import AppleArchive
import System
@testable import LiteZipCore

private struct MoreFormatFixture {
    let root: URL
    let engine: URL
    let codecs: URL
    var service: ArchiveService { restricted() }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LiteZipMoreFormats-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        engine = repo.appendingPathComponent("Vendor/7zip/7zz")
        codecs = repo.appendingPathComponent("Vendor/Formats/bin")
    }
    func restricted(_ limit: Int64 = 100 * 1_024 * 1_024 * 1_024) -> ArchiveService {
        ArchiveService(engineURL: engine, additionalEnginesURL: codecs, maximumExtractedBytes: limit)
    }
    func clean() throws { #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".LiteZip-") }) }
    func close() { try? FileManager.default.removeItem(at: root) }
}

@Suite("ISO and additional codecs")
struct MoreFormatsTests {
    @Test("New format aliases and signatures select the correct handler", arguments: [
        (ArchiveFormat.iso, "iso"), (.wim, "wim"), (.aar, "aar"), (.lzip, "lz"), (.lzip, "lzip"),
        (.lz4, "lz4"), (.brotli, "br"), (.brotli, "brotli"), (.lrzip, "lrz"), (.lrzip, "lrzip"),
        (.snappy, "sz"), (.snappy, "snappy"), (.gzip, "gzip"), (.bzip2, "bzip2")
    ])
    func aliases(format: ArchiveFormat, suffix: String) {
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/not-existing/file." + suffix)) == format)
    }

    @Test("Truncated standalone archives fail without partial results", arguments: [ArchiveFormat.lzip, .lz4, .brotli, .lrzip, .snappy])
    func truncated(format: ArchiveFormat) async throws {
        let f = try MoreFormatFixture(); defer { f.close() }
        let source = f.root.appendingPathComponent("random.bin")
        var bytes = Data(count: 180_111)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        try bytes.write(to: source)
        let archive = try await f.service.compress(files: [source], destination: f.root.appendingPathComponent("bad." + format.suffix), options: .init(format: format))
        let compressed = try Data(contentsOf: archive)
        try compressed.prefix(compressed.count / 2).write(to: archive)
        let output = f.root.appendingPathComponent("out")
        await #expect(throws: LiteZipCore.ArchiveError.self) { _ = try await f.service.list(archive: archive) }
        await #expect(throws: LiteZipCore.ArchiveError.self) { _ = try await f.service.extract(archive: archive, destination: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: source) == bytes)
        try f.clean()
    }

    @Test("AAR rejects traversal, duplicate paths, links and oversized declarations", arguments: ["../escape", "/escape", "duplicate", "link", "oversize"])
    func unsafeAppleArchive(kind: String) async throws {
        let f = try MoreFormatFixture(); defer { f.close() }
        let archive = f.root.appendingPathComponent("unsafe.aar")
        let file = try #require(ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .writeOnly, options: [.create, .exclusiveCreate], permissions: [.ownerReadWrite]))
        let stream = try #require(ArchiveStream.encodeStream(writingTo: file, threadCount: 1))
        let header = ArchiveHeader()
        header.append(.uint(key: .init("TYP"), value: UInt64((kind == "link" ? ArchiveHeader.EntryType.link : .regularFile).rawValue)))
        header.append(.string(key: .init("PAT"), value: kind == "duplicate" || kind == "oversize" || kind == "link" ? "file" : kind))
        if kind == "link" { header.append(.string(key: .init("LNK"), value: "../escape")) }
        if kind == "oversize" { header.append(.blob(key: .init("DAT"), size: 100_000)) }
        try stream.writeHeader(header)
        if kind == "oversize" {
            try Data(count: 100_000).withUnsafeBytes { try stream.writeBlob(key: .init("DAT"), from: $0) }
        }
        if kind == "duplicate" { try stream.writeHeader(header) }
        try stream.close(); try file.close()
        let service = f.restricted(1_024)
        let output = f.root.appendingPathComponent("out")
        // Apple's decoder rejects absolute and traversal paths before returning a header.
        let expected: LiteZipCore.ArchiveError = kind == "link" ? .linksUnsupported : kind == "oversize" ? .tooLarge : kind == "duplicate" ? .unsafePath : .corruptedArchive
        await #expect(throws: expected) { _ = try await service.list(archive: archive) }
        await #expect(throws: expected) { try await service.test(archive: archive) }
        await #expect(throws: expected) { _ = try await service.extract(archive: archive, destination: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try f.clean()
    }
    @Test("Standalone formats round trip Unicode and empty data without changing sources", arguments: [ArchiveFormat.lzip, .lz4, .brotli, .lrzip, .snappy], [false, true])
    func streams(format: ArchiveFormat, empty: Bool) async throws {
        let f = try MoreFormatFixture(); defer { f.close() }
        let source = f.root.appendingPathComponent("中文 [字]* 😀.txt")
        var data = empty ? Data() : Data(count: 140_321)
        if !empty { data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) } }
        try data.write(to: source)
        let outputName = source.lastPathComponent + "." + format.suffix
        let archive = try await f.service.compress(files: [source], destination: f.root.appendingPathComponent(outputName), options: .init(format: format))
        #expect(ArchiveFormat.detect(archive) == format)
        try await f.service.test(archive: archive)
        let entries = try await f.service.list(archive: archive)
        #expect(entries.count == 1 && entries[0].path == source.lastPathComponent && entries[0].size == data.count)
        let result = try await f.service.extract(archive: archive, destination: f.root.appendingPathComponent("output"))
        #expect(try Data(contentsOf: result.appendingPathComponent(source.lastPathComponent)) == data)
        #expect(try Data(contentsOf: source) == data)
        try f.clean()
    }

    @Test("New streams reject folders, linked files and unsupported encryption", arguments: [ArchiveFormat.lzip, .lz4, .brotli, .lrzip, .snappy])
    func streamInputs(format: ArchiveFormat) async throws {
        let f = try MoreFormatFixture(); defer { f.close() }
        let file = f.root.appendingPathComponent("file")
        try Data("unchanged".utf8).write(to: file)
        let link = f.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let dest = f.root.appendingPathComponent("archive." + format.suffix)
        await #expect(throws: ArchiveError.invalidInput) { _ = try await f.service.compress(files: [f.root], destination: dest, options: .init(format: format)) }
        await #expect(throws: ArchiveError.invalidInput) { _ = try await f.service.compress(files: [link], destination: dest, options: .init(format: format)) }
        await #expect(throws: ArchiveError.unsupportedFormat) { _ = try await f.service.compress(files: [file], destination: dest, options: .init(format: format, password: "secret")) }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        try f.clean()
    }

    @Test("Bounded decompression rejects oversized streams without publishing", arguments: [ArchiveFormat.lzip, .lz4, .brotli, .lrzip, .snappy])
    func streamLimit(format: ArchiveFormat) async throws {
        let f = try MoreFormatFixture(); defer { f.close() }
        let file = f.root.appendingPathComponent("large.txt")
        try Data(repeating: 65, count: 200_000).write(to: file)
        let archive = try await f.service.compress(files: [file], destination: f.root.appendingPathComponent("large." + format.suffix), options: .init(format: format))
        let restricted = f.restricted(1_024)
        let output = f.root.appendingPathComponent("out")
        await #expect(throws: ArchiveError.tooLarge) { _ = try await restricted.list(archive: archive) }
        await #expect(throws: ArchiveError.tooLarge) { try await restricted.test(archive: archive) }
        await #expect(throws: ArchiveError.tooLarge) { _ = try await restricted.extract(archive: archive, destination: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try f.clean()
    }

    @Test("ISO, WIM and AAR round trip Unicode trees and exclude Mac resource files", arguments: [ArchiveFormat.iso, .wim, .aar])
    func trees(format: ArchiveFormat) async throws {
        let f = try MoreFormatFixture(); defer { f.close() }
        let dir = f.root.appendingPathComponent("文件夹", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("空目录"), withIntermediateDirectories: true)
        let name = "中文 [字]* 😀.txt", bytes = Data("Tree format! 你好。".utf8)
        try bytes.write(to: dir.appendingPathComponent(name))
        try Data().write(to: dir.appendingPathComponent("empty"))
        try Data("keep".utf8).write(to: dir.appendingPathComponent(".hidden"))
        try Data("remove".utf8).write(to: dir.appendingPathComponent(".DS_Store"))
        let archive = try await f.service.compress(files: [dir], destination: f.root.appendingPathComponent("archive." + format.suffix), options: .init(format: format))
        try await f.service.test(archive: archive)
        let entries = try await f.service.list(archive: archive)
        #expect(!entries.contains { $0.path.contains(".DS_Store") })
        let fileEntry = try #require(entries.first { $0.path.hasSuffix("/" + name) })
        let result = try await f.service.extract(archive: archive, destination: f.root.appendingPathComponent("out"))
        #expect(try Data(contentsOf: result.appendingPathComponent(fileEntry.path)) == bytes)
        #expect(entries.contains { $0.path.hasSuffix("空目录") && $0.isDirectory })
        #expect(entries.contains { $0.path.hasSuffix(".hidden") })
        #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == bytes)
        try f.clean()
    }

    @Test("Native Apple archives retain store, fast and maximum interoperability", arguments: [CompressionLevel.store, .fastest, .maximum])
    func appleAlgorithms(level: CompressionLevel) async throws {
        let f = try MoreFormatFixture(); defer { f.close() }
        let file = f.root.appendingPathComponent("hello.txt")
        try Data("AAR".utf8).write(to: file)
        let archive = try await f.service.compress(files: [file], destination: f.root.appendingPathComponent("apple.aar"), options: .init(format: .aar, level: level))
        let result = try await f.service.extract(archive: archive, destination: f.root.appendingPathComponent("out"))
        #expect(try String(contentsOf: result.appendingPathComponent("hello.txt"), encoding: .utf8) == "AAR")
        try f.clean()
    }
}
