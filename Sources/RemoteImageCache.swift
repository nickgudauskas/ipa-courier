import AppKit
import Foundation

/// Loads card images with caching, a small concurrency limit and retries.
/// GitHub's preview-image service turns away bursts of parallel requests,
/// which AsyncImage never retries.
actor RemoteImageCache {
    static let shared = RemoteImageCache()

    private let memory = NSCache<NSURL, NSImage>()
    private let session: URLSession
    private let maxConcurrent = 3
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// One shared load per URL, so a card and its detail sheet don't fetch twice.
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    private init() {
        let config = URLSessionConfiguration.default
        let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IPA Courier/Images", isDirectory: true)
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20, directory: cacheDirectory)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        memory.countLimit = 300
    }

    /// The first of `urls` that loads.
    func image(for urls: [URL]) async -> NSImage? {
        for url in urls {
            if let image = await image(for: url) { return image }
        }
        return nil
    }

    func image(for url: URL) async -> NSImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        if let task = inFlight[url] { return await task.value }
        let task = Task { await load(url) }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image { memory.setObject(image, forKey: url as NSURL) }
        return image
    }

    private func load(_ url: URL) async -> NSImage? {
        var retryAfter: TimeInterval = 0
        for attempt in 0..<5 {
            if Task.isCancelled { return nil }
            if attempt > 0 {
                // Back off 2, 4, 8, 16 s, or longer if the server asks.
                let delay = max(retryAfter, Double(1 << attempt))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await acquire()
            let result = await fetch(url, bypassCache: attempt > 0)
            release()
            switch result {
            case .image(let image): return image
            case .retry(let after):
                // A long wait means the hourly allowance is used up; show the placeholder instead.
                if let after, after > 20 { return nil }
                retryAfter = after ?? 0
            case .give: return nil
            }
        }
        return nil
    }

    private enum FetchResult {
        case image(NSImage)
        case retry(after: TimeInterval?)
        case give
    }

    private func fetch(_ url: URL, bypassCache: Bool) async -> FetchResult {
        var request = URLRequest(url: url)
        request.setValue("IPA-Courier", forHTTPHeaderField: "User-Agent")
        if bypassCache { request.cachePolicy = .reloadIgnoringLocalCacheData }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .retry(after: nil) }
        guard http.statusCode == 200, let image = NSImage(data: data) else {
            // Never keep an error page (e.g. 429 Too Many Requests) in the cache.
            session.configuration.urlCache?.removeCachedResponse(for: request)
            if http.statusCode == 404 { return .give }
            return .retry(after: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        }
        return .image(image)
    }

    private func acquire() async {
        if active < maxConcurrent {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            active -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
