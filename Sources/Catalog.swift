import Foundation

// MARK: - Catalog format (Resources/catalog.json)

struct Catalog: Codable {
    let version: Int
    let notice: String?
    let projects: [CatalogProject]
    let padmint: PadMintInfo?
}

struct PadMintInfo: Codable, Hashable {
    let repo: String
    let summary: String?
}

struct AssetRule: Codable, Hashable {
    /// Regular expression matched against release asset file names.
    let asset: String
}

struct CatalogProject: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let game: String
    let console: String
    let kind: String
    let repo: String
    let summary: String
    let requires: String
    let mac: AssetRule?
    let ios: AssetRule?
    /// Built into a playable app with PadMint from the user's own game file.
    let padmint: Bool?

    var usesPadMint: Bool { padmint == true }
    var repoURL: URL { URL(string: "https://github.com/\(repo)")! }
    var releasesURL: URL { URL(string: "https://github.com/\(repo)/releases/latest")! }
    /// GitHub's generated social preview card; works for every public repo without a key.
    var imageURL: URL { URL(string: "https://opengraph.githubassets.com/1/\(repo)")! }

    /// The copy of that card published with the release index (served by GitHub's file CDN),
    /// then the card itself, whose service allows only about 100 requests per IP at a time.
    var imageURLs: [URL] {
        let published = "https://raw.githubusercontent.com/nickgudauskas/ipa-courier/release-index/images/"
            + repo.replacingOccurrences(of: "/", with: "__") + ".png"
        return [URL(string: published)!, imageURL]
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return [name, game, console, kind, repo].contains { $0.localizedCaseInsensitiveContains(q) }
    }
}

// MARK: - GitHub releases

struct ReleaseAsset: Codable, Hashable {
    let name: String
    let size: Int64
    let downloadURL: URL
}

struct Release: Codable, Hashable {
    let tag: String
    let name: String?
    let publishedAt: Date?
    let pageURL: URL
    let assets: [ReleaseAsset]

    /// The asset a rule selects, preferring Apple silicon builds when there are several.
    func asset(for rule: AssetRule?) -> ReleaseAsset? {
        guard let rule, let regex = try? NSRegularExpression(pattern: rule.asset, options: [.caseInsensitive]) else {
            return nil
        }
        let matching = assets.filter { asset in
            regex.firstMatch(in: asset.name, range: NSRange(asset.name.startIndex..., in: asset.name)) != nil
        }
        func score(_ name: String) -> Int {
            let lower = name.lowercased()
            if ["arm64", "aarch64", "_arm", "-arm", "universal", "apple-silicon"].contains(where: lower.contains) { return 2 }
            if ["x86_64", "x64", "intel", "amd64"].contains(where: lower.contains) { return 0 }
            return 1
        }
        return matching.max { score($0.name) < score($1.name) }
    }
}

enum CatalogError: LocalizedError {
    case rateLimited(Date?)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .rateLimited(let reset):
            let when = reset.map { " Try again after \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
            return "GitHub's hourly limit for release checks was reached.\(when)"
        case .http(let code, let repo):
            return "GitHub returned \(code) for \(repo)."
        }
    }
}

/// Fetches latest releases with ETag caching, so unchanged releases don't
/// count against GitHub's 60-requests-per-hour anonymous limit.
actor ReleaseService {
    static let shared = ReleaseService()

    private struct CacheEntry: Codable {
        let etag: String?
        let release: Release
        let fetchedAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var loaded = false
    private let cacheURL = AppPaths.support.appendingPathComponent("release-cache.json")

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: cacheURL),
           let entries = try? Self.decoder.decode([String: CacheEntry].self, from: data) {
            cache = entries
        }
    }

    private func saveCache() {
        if let data = try? Self.encoder.encode(cache) { try? data.write(to: cacheURL) }
    }

    /// Latest release for `repo`. Uses the cache for `maxAge` seconds unless `force`.
    func latest(_ repo: String, force: Bool = false, maxAge: TimeInterval = 30 * 60) async throws -> Release {
        loadCache()
        let cached = cache[repo]
        if let cached, !force, Date().timeIntervalSince(cached.fetchedAt) < maxAge {
            return cached.release
        }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("IPA-Courier", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CatalogError.http(0, repo) }

        switch http.statusCode {
        case 304:
            if let cached {
                cache[repo] = CacheEntry(etag: cached.etag, release: cached.release, fetchedAt: Date())
                saveCache()
                return cached.release
            }
            throw CatalogError.http(304, repo)
        case 200:
            let release = try Self.parse(data)
            cache[repo] = CacheEntry(etag: http.value(forHTTPHeaderField: "ETag"), release: release, fetchedAt: Date())
            saveCache()
            return release
        case 403, 429:
            if let cached { return cached.release }
            let reset = http.value(forHTTPHeaderField: "x-ratelimit-reset")
                .flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            throw CatalogError.rateLimited(reset)
        default:
            if let cached { return cached.release }
            throw CatalogError.http(http.statusCode, repo)
        }
    }

    private static func parse(_ data: Data) throws -> Release {
        struct Raw: Decodable {
            struct Asset: Decodable {
                let name: String
                let size: Int64
                let browser_download_url: URL
            }
            let tag_name: String
            let name: String?
            let published_at: Date?
            let html_url: URL
            let assets: [Asset]
        }
        let raw = try decoder.decode(Raw.self, from: data)
        return Release(tag: raw.tag_name, name: raw.name, publishedAt: raw.published_at, pageURL: raw.html_url,
                       assets: raw.assets.map { ReleaseAsset(name: $0.name, size: $0.size, downloadURL: $0.browser_download_url) })
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

// MARK: - Release index

/// releases.json, built every few hours by .github/workflows/release-index.yml:
/// the latest release of every catalog project in one download.
struct ReleaseIndex: Codable {
    let generatedAt: Date?
    let releases: [String: Release]

    static let remoteURL = URL(string: "https://raw.githubusercontent.com/nickgudauskas/ipa-courier/release-index/releases.json")!
    private static var cachedURL: URL { AppPaths.support.appendingPathComponent("releases-index.json") }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// The published index, else the last downloaded copy.
    static func load() async -> ReleaseIndex? {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let index = try? decoder.decode(ReleaseIndex.self, from: data) {
            try? data.write(to: cachedURL)
            return index
        }
        if let data = try? Data(contentsOf: cachedURL) {
            return try? decoder.decode(ReleaseIndex.self, from: data)
        }
        return nil
    }
}

// MARK: - Loading the catalog

enum CatalogLoader {
    /// The catalog published in the IPA Courier repository, so it can grow without app updates.
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/nickgudauskas/ipa-courier/main/Resources/catalog.json")!
    private static var cachedURL: URL { AppPaths.support.appendingPathComponent("catalog.json") }

    /// Remote catalog when reachable, else the last downloaded copy, else the one bundled with the app.
    static func load() async -> (Catalog?, source: String) {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let catalog = try? JSONDecoder().decode(Catalog.self, from: data) {
            try? data.write(to: cachedURL)
            return (catalog, "GitHub")
        }
        if let data = try? Data(contentsOf: cachedURL),
           let catalog = try? JSONDecoder().decode(Catalog.self, from: data) {
            return (catalog, "saved copy")
        }
        if let url = Bundle.main.url(forResource: "catalog", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let catalog = try? JSONDecoder().decode(Catalog.self, from: data) {
            return (catalog, "built-in copy")
        }
        return (nil, "none")
    }
}
