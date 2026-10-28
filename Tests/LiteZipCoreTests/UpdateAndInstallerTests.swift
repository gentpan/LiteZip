import Foundation
import Testing
@testable import LiteZipCore

@Suite("Update check")
struct UpdateCheckTests {
    private func release(_ tag: String, draft: Bool = false) -> UpdateCheck.Release {
        .init(tagName: tag, htmlURL: URL(string: "https://github.com/gentpan/LiteZip/releases/tag/\(tag)")!, draft: draft, prerelease: true)
    }

    @Test("Version tags compare numerically")
    func versions() {
        #expect(UpdateCheck.versionComponents("v0.5.0") == [0, 5, 0])
        #expect(UpdateCheck.versionComponents("1.2") == [1, 2])
        #expect(UpdateCheck.versionComponents("v1.0-beta") == nil)
        #expect(UpdateCheck.versionComponents("nightly") == nil)
        #expect(UpdateCheck.isNewer("v0.10.0", than: "0.9.9"))
        #expect(UpdateCheck.isNewer("v0.5.1", than: "0.5"))
        #expect(!UpdateCheck.isNewer("v0.5.0", than: "0.5"))
        #expect(!UpdateCheck.isNewer("v0.4.9", than: "0.5.0"))
        #expect(!UpdateCheck.isNewer("garbage", than: "0.5.0"))
    }

    @Test("Newest published release wins; drafts and odd tags are ignored")
    func newest() {
        let releases = [release("v0.5.0"), release("v0.7.0", draft: true), release("v0.6.1"), release("v0.6.0"), release("latest")]
        #expect(UpdateCheck.newestRelease(in: releases, newerThan: "0.5.0")?.tagName == "v0.6.1")
        #expect(UpdateCheck.newestRelease(in: releases, newerThan: "0.6.1") == nil)
    }

    @Test("GitHub release JSON decodes and notes are shortened")
    func decoding() throws {
        let json = ###"[{"tag_name":"v0.6.0","name":"LiteZip 0.6.0","html_url":"https://github.com/gentpan/LiteZip/releases/tag/v0.6.0","body":"## LiteZip 0.6.0\n\n- 新功能\n- 修复","draft":false,"prerelease":true}]"###
        let releases = try JSONDecoder().decode([UpdateCheck.Release].self, from: Data(json.utf8))
        #expect(releases.first?.version == "0.6.0")
        #expect(releases.first?.notesSummary == "- 新功能\n- 修复")
    }
}

@Suite("RAR engine download")
struct RARInstallerTests {
    @Test("Stable macOS packages are found on the download page; betas are skipped")
    func downloadLinks() {
        let page = """
        <a href="/rar/rarmacos-arm64-730b2.tar.gz"><b>RAR for macOS ARM64 7.30 beta 2</b></a>
        <a href="/rar/rarmacos-arm-723.tar.gz"><b>RAR for macOS ARM64 7.23</b></a>
        <a href="/rar/rarmacos-arm-713.tar.gz"><b>RAR for macOS ARM64 7.13</b></a>
        """
        #expect(RARInstaller.packageURL(inDownloadPage: page, architecture: .arm64)?.absoluteString == "https://www.rarlab.com/rar/rarmacos-arm-723.tar.gz")
        #expect(RARInstaller.packageURL(inDownloadPage: page, architecture: .x86_64)?.absoluteString == "https://www.rarlab.com/rar/rarmacos-x64-723.tar.gz")
        let intel = page + #"<a href="/rar/rarmacos-x64-720.tar.gz">"#
        #expect(RARInstaller.packageURL(inDownloadPage: intel, architecture: .x86_64)?.absoluteString == "https://www.rarlab.com/rar/rarmacos-x64-720.tar.gz")
        #expect(RARInstaller.packageURL(inDownloadPage: "<html>no packages</html>", architecture: .arm64) == nil)
    }

    private func makePackage(in root: URL, header: String, license: Bool = true) throws -> URL {
        let source = root.appendingPathComponent("source-" + UUID().uuidString)
        let folder = source.appendingPathComponent("rar")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("rar")
        try Data("#!/bin/sh\necho '\(header)'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        if license { try Data("RAR license".utf8).write(to: folder.appendingPathComponent("license.txt")) }
        let package = root.appendingPathComponent(UUID().uuidString + ".tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", package.path, "-C", source.path, "rar"]
        try tar.run(); tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        return package
    }

    @Test("A checked package replaces the earlier copy; a bad one leaves it in place")
    func install() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiteZipRARInstall-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Support/RAR")

        let first = try makePackage(in: root, header: "RAR 7.13   Copyright (c) 1993-2025 Alexander Roshal   1 Jan 2025")
        let installed = try await RARInstaller.install(package: first, into: target)
        #expect(installed.version == "RAR 7.13")
        #expect(installed.executable == target.appendingPathComponent("rar/rar"))
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("rar/license.txt").path))

        let update = try makePackage(in: root, header: "RAR 7.23   Copyright (c) 1993-2026 Alexander Roshal   27 Jun 2026")
        #expect(try await RARInstaller.install(package: update, into: target).version == "RAR 7.23")

        let fake = try makePackage(in: root, header: "UNRAR 7.23 freeware")
        await #expect(throws: ArchiveError.invalidRAREngine) { _ = try await RARInstaller.install(package: fake, into: target) }
        let incomplete = try makePackage(in: root, header: "RAR 7.30   Copyright (c) 1993-2026 Alexander Roshal", license: false)
        await #expect(throws: ArchiveError.invalidRAREngine) { _ = try await RARInstaller.install(package: incomplete, into: target) }
        #expect(try await RAREngine.version(at: target.appendingPathComponent("rar/rar")) == "RAR 7.23")
        // Only the installed folder remains; staging and previous copies are cleaned up.
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["RAR"])
    }
}
