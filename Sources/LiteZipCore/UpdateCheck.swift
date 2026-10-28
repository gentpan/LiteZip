import Foundation

/// Reads LiteZip's public GitHub releases. Nothing identifying is sent and nothing is downloaded.
public enum UpdateCheck {
    public static let releasesURL = URL(string: "https://api.github.com/repos/gentpan/LiteZip/releases?per_page=20")!

    public struct Release: Decodable, Sendable, Equatable {
        public let tagName: String
        public let name: String?
        public let htmlURL: URL
        public let body: String?
        public let draft: Bool
        public let prerelease: Bool
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", name, htmlURL = "html_url", body, draft, prerelease
        }
        public init(tagName: String, name: String? = nil, htmlURL: URL, body: String? = nil, draft: Bool = false, prerelease: Bool = false) {
            self.tagName = tagName; self.name = name; self.htmlURL = htmlURL; self.body = body; self.draft = draft; self.prerelease = prerelease
        }
        public var version: String { tagName.hasPrefix("v") || tagName.hasPrefix("V") ? String(tagName.dropFirst()) : tagName }
        /// The first part of the release notes, short enough for an alert.
        public var notesSummary: String? {
            guard let body = body?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return nil }
            let lines = body.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            let text = lines.prefix(8).joined(separator: "\n")
            return text.count > 600 ? String(text.prefix(600)) + "…" : text
        }
    }

    /// "v0.5.0" → [0, 5, 0]. Tags of any other shape are not treated as versions.
    public static func versionComponents(_ text: String) -> [Int]? {
        var value = Substring(text.trimmingCharacters(in: .whitespaces))
        if value.first == "v" || value.first == "V" { value = value.dropFirst() }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers = [Int]()
        for part in parts {
            guard !part.isEmpty, part.count <= 6, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = versionComponents(candidate), let old = versionComponents(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0, b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Every LiteZip build so far is published as a GitHub pre-release, so pre-releases count.
    public static func newestRelease(in releases: [Release], newerThan current: String) -> Release? {
        releases.filter { !$0.draft && isNewer($0.tagName, than: current) }
            .max { isNewer($1.tagName, than: $0.tagName) }
    }

    public static func fetchReleases() async throws -> [Release] {
        let data = try await Network.data(from: releasesURL, limit: 4 * 1_024 * 1_024, accept: "application/vnd.github+json")
        return try JSONDecoder().decode([Release].self, from: data)
    }
}

enum Network {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }()

    /// HTTPS only, including after redirects, with a size cap for every response.
    static func data(from url: URL, limit: Int, accept: String? = nil) async throws -> Data {
        guard url.scheme == "https" else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("LiteZip", forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.scheme == "https" else {
            throw URLError(.badServerResponse)
        }
        guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}
