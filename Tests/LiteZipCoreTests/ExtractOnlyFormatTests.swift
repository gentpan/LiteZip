import Foundation
import Darwin
import Testing
@testable import LiteZipCore

private struct ExtractOnlyFixture {
    let root: URL
    let service: ArchiveService
    let lzop: URL
    init(limit: Int64 = 100 * 1_024 * 1_024 * 1_024) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LiteZipExtractOnly-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        service = ArchiveService(engineURL: repo.appendingPathComponent("Vendor/7zip/7zz"), additionalEnginesURL: repo.appendingPathComponent("Vendor/Formats/bin"), maximumExtractedBytes: limit)
        lzop = repo.appendingPathComponent("Vendor/Formats/bin/lzop")
    }
    func close() { try? FileManager.default.removeItem(at: root) }
    func fixture(_ name: String) -> URL { Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")! }
    /// A private copy under a chosen name, so tests can strip or change the extension.
    func copy(_ fixture: String, as name: String) throws -> URL {
        let target = root.appendingPathComponent(name)
        try FileManager.default.copyItem(at: self.fixture(fixture), to: target)
        return target
    }
    func assertClean() throws {
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".LiteZip-") })
    }
}

@Suite("Extract-only formats")
struct ExtractOnlyFormatTests {
    static let formats: [ArchiveFormat] = [.cab, .cpio, .lzh, .lzma, .z, .lzop]

    @Test("Extension aliases select the right format", arguments: [
        (ArchiveFormat.cab, "cab"), (.cpio, "cpio"), (.lzh, "lzh"), (.lzh, "lha"), (.lzma, "lzma"),
        (.z, "z"), (.z, "Z"), (.lzop, "lzo"), (.lzop, "lzop")
    ])
    func aliases(format: ArchiveFormat, suffix: String) {
        #expect(ArchiveFormat.detect(URL(fileURLWithPath: "/not-existing/file." + suffix)) == format)
    }

    @Test("Signatures identify files without an extension", arguments: [
        ("libarchive.cab", ArchiveFormat.cab), ("plain.lzh", .lzh), ("sample.txt.Z", .z), ("sample.txt.lzo", .lzop)
    ])
    func signatures(fixture: String, format: ArchiveFormat) throws {
        let f = try ExtractOnlyFixture(); defer { f.close() }
        #expect(ArchiveFormat.detect(try f.copy(fixture, as: "no-extension")) == format)
    }

    @Test("These formats are never offered for creation", arguments: ExtractOnlyFormatTests.formats)
    func neverCreated(format: ArchiveFormat) async throws {
        #expect(format.extractOnly)
        #expect(!format.canCreate)
        let f = try ExtractOnlyFixture(); defer { f.close() }
        let source = f.root.appendingPathComponent("input.txt")
        try Data("input".utf8).write(to: source)
        await #expect(throws: ArchiveError.unsupportedFormat) {
            _ = try await f.service.compress(files: [source], destination: f.root.appendingPathComponent("out." + format.suffix), options: .init(format: format))
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("out." + format.suffix).path))
    }

    @Test("Multi-file archives list, verify and extract with exact contents", arguments: [
        ("libarchive.cab", ArchiveFormat.cab, ["empty": 0, "dir1/file1": 60, "dir2/file2": 78]),
        ("sample.cpio", .cpio, ["top.txt": 10, "docs/说明.txt": 34]),
        ("plain.lzh", .lzh, ["readme.txt": 18, "data.bin": 64])
    ])
    func multiFile(name: String, format: ArchiveFormat, expected: [String: Int]) async throws {
        let f = try ExtractOnlyFixture(); defer { f.close() }
        let input = f.fixture(name)
        #expect(ArchiveFormat.detect(input) == format)
        let entries = try await f.service.list(archive: input).filter { !$0.isDirectory }
        #expect(Dictionary(uniqueKeysWithValues: entries.map { ($0.path, Int($0.size)) }) == expected)
        try await f.service.test(archive: input)
        let output = try await f.service.extract(archive: input, destination: f.root.appendingPathComponent("out"))
        for (path, size) in expected {
            #expect(try Data(contentsOf: output.appendingPathComponent(path)).count == size)
        }
        try f.assertClean()
    }

    @Test("Stored LHA and CPIO keep exact bytes and Unicode names")
    func exactBytes() async throws {
        let f = try ExtractOnlyFixture(); defer { f.close() }
        let lha = try await f.service.extract(archive: f.fixture("plain.lzh"), destination: f.root.appendingPathComponent("lha"))
        #expect(try Data(contentsOf: lha.appendingPathComponent("data.bin")) == Data(0..<64))
        #expect(try String(contentsOf: lha.appendingPathComponent("readme.txt"), encoding: .utf8) == "lha store fixture\n")
        let cpio = try await f.service.extract(archive: f.fixture("sample.cpio"), destination: f.root.appendingPathComponent("cpio"))
        #expect(try String(contentsOf: cpio.appendingPathComponent("docs/说明.txt"), encoding: .utf8) == "中文内容 extract-only fixture\n")
    }

    @Test("Single-stream formats take the archive name and decode exactly", arguments: [
        ("sample.txt.lzma", ArchiveFormat.lzma, "lzma single stream\n"),
        ("sample.txt.Z", .z, "unix compress stream\n"),
        ("sample.txt.lzo", .lzop, "lzop stream 中文\n")
    ])
    func singleStream(name: String, format: ArchiveFormat, text: String) async throws {
        let f = try ExtractOnlyFixture(); defer { f.close() }
        let input = f.fixture(name)
        #expect(ArchiveFormat.detect(input) == format)
        #expect(format.singleFileOnly)
        #expect(ArchiveFormat.baseName(input) == "sample.txt")
        #expect(try await f.service.list(archive: input).map(\.path) == ["sample.txt"])
        try await f.service.test(archive: input)
        let output = try await f.service.extract(archive: input, destination: f.root.appendingPathComponent("out"))
        #expect(try String(contentsOf: output.appendingPathComponent("sample.txt"), encoding: .utf8) == text)
        try f.assertClean()
    }

    @Test("An lzop stream made by another implementation decodes to its TAR")
    func thirdPartyLZOP() async throws {
        let f = try ExtractOnlyFixture(); defer { f.close() }
        let input = f.fixture("libarchive.tar.lzo")
        #expect(ArchiveFormat.baseName(input) == "libarchive.tar")
        let output = try await f.service.extract(archive: input, destination: f.root.appendingPathComponent("out"))
        let tar = try Data(contentsOf: output.appendingPathComponent("libarchive.tar"))
        #expect(tar.count >= 512)
        #expect(String(decoding: tar.prefix(7), as: UTF8.self) == "INSTALL")
        try f.assertClean()
    }

    @Test("LHA symbolic links are rejected without publishing anything")
    func symbolicLinks() async throws {
        let f = try ExtractOnlyFixture(); defer { f.close() }
        let input = f.fixture("symlinks.lzh")
        let output = f.root.appendingPathComponent("out")
        await #expect(throws: ArchiveError.linksUnsupported) { _ = try await f.service.list(archive: input) }
        await #expect(throws: ArchiveError.linksUnsupported) { try await f.service.test(archive: input) }
        await #expect(throws: ArchiveError.linksUnsupported) { _ = try await f.service.extract(archive: input, destination: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try f.assertClean()
    }

    /// Unix compress (.Z) is left out: LZW streams carry no length or checksum, so a
    /// truncated one decodes to a shorter file and cannot be told apart from a good one.
    @Test("Truncated streams fail verification and extraction without partial results", arguments: ["sample.txt.lzo", "sample.txt.lzma", "libarchive.tar.lzo"])
    func truncatedStreams(name: String) async throws {
        let f = try ExtractOnlyFixture(); defer { f.close() }
        let original = try Data(contentsOf: f.fixture(name))
        let truncated = f.root.appendingPathComponent("short." + f.fixture(name).pathExtension)
        try original.prefix(max(21, original.count / 2)).write(to: truncated)
        let output = f.root.appendingPathComponent("out")
        // lzop is decoded to count its size, so even the preview fails; 7-Zip streams only fail on read.
        if ArchiveFormat.detect(truncated) == .lzop {
            await #expect(throws: ArchiveError.self) { _ = try await f.service.list(archive: truncated) }
        }
        await #expect(throws: ArchiveError.self) { try await f.service.test(archive: truncated) }
        await #expect(throws: ArchiveError.self) { _ = try await f.service.extract(archive: truncated, destination: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try f.assertClean()
    }

    @Test("Random bytes named .lzo are rejected")
    func notLZOP() async throws {
        let f = try ExtractOnlyFixture(); defer { f.close() }
        var bytes = Data(count: 4_096)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
        let input = f.root.appendingPathComponent("noise.lzo")
        try bytes.write(to: input)
        await #expect(throws: ArchiveError.self) {
            _ = try await f.service.extract(archive: input, destination: f.root.appendingPathComponent("out"))
        }
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("out").path))
        try f.assertClean()
    }

    @Test("The decompression limit stops an lzop bomb")
    func lzopLimit() async throws {
        let f = try ExtractOnlyFixture(limit: 64 * 1_024); defer { f.close() }
        let plain = f.root.appendingPathComponent("zeros.bin")
        try Data(count: 4 * 1_024 * 1_024).write(to: plain)
        let packed = f.root.appendingPathComponent("zeros.bin.lzo")
        _ = try ProcessRunner(executable: f.lzop).run(["-q", "-o", packed.path, "--", plain.path], control: .init())
        #expect(try Data(contentsOf: packed).count < 64 * 1_024)
        let output = f.root.appendingPathComponent("out")
        await #expect(throws: ArchiveError.tooLarge) {
            _ = try await f.service.extract(archive: packed, destination: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try f.assertClean()
    }
}
