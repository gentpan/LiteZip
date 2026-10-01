import Foundation

public enum VolumeSize {
    public static let minimum: Int64 = 1_024 * 1_024
    public static let maximum: Int64 = 1_024 * 1_024 * 1_024 * 1_024
    /// Empty means no volumes. Bare numbers are MB; units are binary multiples.
    public static func parse(_ text: String) throws -> Int64? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !input.isEmpty else { return nil }
        let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*(KB|KIB|MB|MIB|GB|GIB|TB|TIB)?$"#
        let expression = try NSRegularExpression(pattern: pattern)
        guard let match = expression.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)),
              let numberRange = Range(match.range(at: 1), in: input), let number = Double(input[numberRange]) else { throw ArchiveError.invalidVolumeSize }
        let unit = Range(match.range(at: 2), in: input).map { String(input[$0]) } ?? "MB"
        let powers = ["KB": 1, "KIB": 1, "MB": 2, "MIB": 2, "GB": 3, "GIB": 3, "TB": 4, "TIB": 4]
        let bytes = number * pow(1_024, Double(powers[unit]!))
        guard bytes.isFinite, bytes >= Double(minimum), bytes <= Double(maximum) else { throw ArchiveError.invalidVolumeSize }
        return Int64(bytes.rounded(.down))
    }
}

public struct PlannedArchive: Sendable {
    public let files: [URL]
    public let destination: URL
}

public enum CompressionPlanning {
    public static func name(for file: URL, format: ArchiveFormat) -> String {
        let isDirectory = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let stem = isDirectory || format.singleFileOnly ? file.lastPathComponent : file.deletingPathExtension().lastPathComponent
        return (stem.isEmpty ? file.lastPathComponent : stem) + "." + format.suffix
    }
    public static func separate(files: [URL], directory: URL, format: ArchiveFormat) throws -> [PlannedArchive] {
        guard !files.isEmpty, format.canCreate else { throw ArchiveError.invalidInput }
        let inputs = files.map(\.standardizedFileURL)
        guard Set(inputs).count == inputs.count else { throw ArchiveError.invalidInput }
        return inputs.map { PlannedArchive(files: [$0], destination: directory.appendingPathComponent(name(for: $0, format: format))) }
    }
    static func isMacResource(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._")
    }
}
