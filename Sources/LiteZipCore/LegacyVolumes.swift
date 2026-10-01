import Foundation

/// Spanned ZIP reads its final .zip central directory; old RAR starts at .rar.
struct LegacyVolume {
    let url: URL
    let stem: String
    let format: ArchiveFormat
    let index: Int
    let canonical: Bool

    init?(_ url: URL, includeTerminal: Bool = false) {
        let ext = url.pathExtension.lowercased()
        let stem = url.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return nil }
        let format: ArchiveFormat
        let index: Int
        let canonical: Bool
        if ext == "zip" || ext == "rar" {
            format = ext == "zip" ? .zip : .rar
            let firstPart = url.deletingPathExtension().appendingPathExtension(ext == "zip" ? "z01" : "r00")
            guard includeTerminal || FileManager.default.fileExists(atPath: firstPart.path) else { return nil }
            index = 0; canonical = true
        } else {
            guard let letter = ext.first, ext.count >= 3 else { return nil }
            let digits = String(ext.dropFirst())
            guard digits.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(digits) else { return nil }
            if letter == "z", number > 0 {
                // zNN can be ZIP or the last block of old RAR's rNN...zNN names.
                let rar = url.deletingPathExtension().appendingPathExtension("rar")
                let zip = url.deletingPathExtension().appendingPathExtension("zip")
                if digits.count == 2, FileManager.default.fileExists(atPath: rar.path), !FileManager.default.fileExists(atPath: zip.path) {
                    format = .rar; index = 801 + number; canonical = number <= 99
                } else {
                    format = .zip; index = number; canonical = digits == String(format: "%02d", number) && number <= 10_000
                }
            } else if let ascii = letter.asciiValue, (114...122).contains(ascii), digits.count == 2, number <= 99 {
                format = .rar; index = Int(ascii - 114) * 100 + number + 1; canonical = true
            } else { return nil }
        }
        self.url = url; self.stem = stem; self.format = format; self.index = index; self.canonical = canonical
    }
    var firstURL: URL {
        let expected = url.deletingPathExtension().appendingPathExtension(format.suffix)
        if FileManager.default.fileExists(atPath: expected.path) { return expected }
        return (try? ArchiveSafety.directoryContents(url.deletingLastPathComponent()))?.first {
            $0.lastPathComponent.lowercased() == expected.lastPathComponent.lowercased()
        } ?? expected
    }
}

extension ArchiveService {
    func validatedLegacyInput(_ archive: URL) throws -> URL? {
        guard let part = LegacyVolume(archive, includeTerminal: true) else { return nil }
        var indices = Set<Int>()
        let siblings = try ArchiveSafety.directoryContents(archive.deletingLastPathComponent())
        for file in siblings {
            guard let sibling = LegacyVolume(file, includeTerminal: true), sibling.format == part.format,
                  sibling.stem.lowercased() == part.stem.lowercased() else { continue }
            guard sibling.canonical, indices.insert(sibling.index).inserted else { throw ArchiveError.missingVolume }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw ArchiveError.linksUnsupported }
        }
        // A normal standalone ZIP/RAR is also a valid terminal candidate.
        guard let last = indices.max(), indices.contains(0), indices.count == last + 1 else { throw ArchiveError.missingVolume }
        return part.firstURL
    }
}
