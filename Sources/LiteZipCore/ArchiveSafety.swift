import Foundation

public enum ArchiveSafety {
    /// Foundation silently hides AppleDouble entries on macOS. Source inspection
    /// and snapshots must see them so the exclusion option controls the result.
    static func directoryContents(_ url: URL) throws -> [URL] {
        guard let directory = opendir(url.path) else { throw ArchiveError.permissionDenied }
        defer { closedir(directory) }
        var result = [URL]()
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw ArchiveError.permissionDenied }
                return result
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(validatingCString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            guard let name else { throw ArchiveError.ambiguousListing }
            if name != "." && name != ".." { result.append(url.appendingPathComponent(name)) }
        }
    }
    public static func validate(path: String) throws {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains(":"),
              !normalized.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              normalized.utf8.count <= 4096 else { throw ArchiveError.unsafePath }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else { throw ArchiveError.unsafePath }
        // A backslash is legal on macOS, but interpreted as a separator by some engines.
        guard !path.contains("\\") else { throw ArchiveError.unsafePath }
    }
    public static func validate(entries: [ArchiveEntry], maximumBytes: Int64) throws -> Int64 {
        guard entries.count <= 200_000 else { throw ArchiveError.tooLarge }
        var paths = [String: Bool](), total: Int64 = 0
        for entry in entries {
            try validate(path: entry.path)
            let key = entry.path.precomposedStringWithCanonicalMapping.lowercased()
            guard paths[key] == nil else { throw ArchiveError.unsafePath }
            paths[key] = entry.isDirectory
            guard entry.size >= 0, entry.size <= maximumBytes - total else { throw ArchiveError.tooLarge }
            total += entry.size
        }
        for key in paths.keys {
            let parts = key.split(separator: "/")
            for count in 1..<parts.count {
                if paths[parts.prefix(count).joined(separator: "/")] == false { throw ArchiveError.unsafePath }
            }
        }
        return total
    }
    public static func parseListing(_ text: String, fallbackPath: String? = nil) throws -> [ArchiveEntry] {
        var entries = [ArchiveEntry](), fields = [String: String]()
        func append() throws {
            guard !fields.isEmpty else { return }
            guard let path = fields["Path"] ?? fallbackPath, let rawSize = fields["Size"] else { throw ArchiveError.ambiguousListing }
            let known = Int64(rawSize) != nil
            guard known || (rawSize.isEmpty && fallbackPath != nil) else { throw ArchiveError.ambiguousListing }
            let size = Int64(rawSize) ?? 0
            guard size >= 0 else { throw ArchiveError.ambiguousListing }
            let attributes = fields["Attributes"] ?? ""
            let mode = fields["Mode"] ?? attributes.split(separator: " ").last.map(String.init) ?? ""
            if fields.contains(where: { $0.key.lowercased().contains("link") && !$0.value.isEmpty }) || mode.hasPrefix("l") || mode.hasPrefix("b") || mode.hasPrefix("c") || mode.hasPrefix("p") || mode.hasPrefix("s") {
                throw ArchiveError.linksUnsupported
            }
            var normalized = path
            while normalized.hasPrefix("./") { normalized = String(normalized.dropFirst(2)) }
            let isDirectory = fields["Folder"] == "+" || attributes.hasPrefix("D") || mode.hasPrefix("d")
            if isDirectory && normalized.hasSuffix("/") { normalized.removeLast() }
            if normalized.isEmpty && isDirectory { fields.removeAll(keepingCapacity: true); return }
            entries.append(ArchiveEntry(path: normalized, sourcePath: fields["Path"] ?? "", size: size, sizeKnown: known, isDirectory: fields["Folder"] == "+" || attributes.hasPrefix("D") || mode.hasPrefix("d"), encrypted: fields["Encrypted"] == "+"))
            fields.removeAll(keepingCapacity: true)
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty { try append(); continue }
            if line == "Enter password:" && fields.isEmpty { continue }
            guard let separator = line.range(of: " = ") else { throw ArchiveError.ambiguousListing }
            let key = String(line[..<separator.lowerBound]), value = String(line[separator.upperBound...])
            guard !key.isEmpty, fields[key] == nil else { throw ArchiveError.ambiguousListing }
            fields[key] = value
        }
        try append()
        return entries
    }
    static func availableBytes(at directory: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }
}
