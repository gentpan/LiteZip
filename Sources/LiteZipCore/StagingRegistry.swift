import Foundation
import Darwin

/// A small local journal lets the next launch find crash leftovers without scanning user folders.
enum StagingRegistry {
    private struct Record: Codable {
        let path: String
        let createdAt: Date
        let processID: Int32
    }
    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app.litezip.LiteZip/Staging", isDirectory: true)
    }
    private static func manifest(for url: URL) -> URL { directory.appendingPathComponent(url.lastPathComponent + ".json") }
    static func register(_ url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Record(path: url.path, createdAt: Date(), processID: getpid())).write(to: manifest(for: url), options: .atomic)
    }
    static func remove(_ url: URL) {
        do {
            guard PrivateDiskImageMount.detach(inside: url) else { return }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try? FileManager.default.removeItem(at: manifest(for: url))
        } catch { /* Leave the journal for a later cleanup attempt. */ }
    }
    static func cleanup() {
        let fm = FileManager.default
        guard let records = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for manifest in records where manifest.pathExtension == "json" {
            guard let data = try? Data(contentsOf: manifest), data.count < 16_384,
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  record.createdAt < Date().addingTimeInterval(-86_400),
                  kill(record.processID, 0) != 0 && errno == ESRCH else { continue }
            let url = URL(fileURLWithPath: record.path)
            guard url.lastPathComponent.hasPrefix(".LiteZip-"), UUID(uuidString: String(url.lastPathComponent.dropFirst(9))) != nil,
                  self.manifest(for: url).lastPathComponent == manifest.lastPathComponent else { continue }
            var metadata = stat()
            if lstat(url.path, &metadata) != 0 { try? fm.removeItem(at: manifest); continue }
            guard metadata.st_uid == getuid(), metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o777 == 0o700 else { continue }
            remove(url)
        }
    }
}

extension ArchiveService {
    public static func cleanupAbandonedTemporaryFiles() { StagingRegistry.cleanup() }
}
