import Foundation

/// An IPA in the user's library folder, indexed by bundle ID.
struct LibraryEntry: Codable, Identifiable, Equatable {
    let path: String
    let bundleID: String
    let name: String
    let version: String
    let modified: Date
    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

/// Finds the IPAs that installed apps came from, so they can be re-signed.
enum Library {
    private static var cacheURL: URL { AppPaths.support.appendingPathComponent("library-index.json") }
    private static var ledgerURL: URL { AppPaths.support.appendingPathComponent("installs.json") }

    static var folder: URL? {
        get { UserDefaults.standard.string(forKey: "libraryFolder").map { URL(fileURLWithPath: $0) } }
        set { UserDefaults.standard.set(newValue?.path, forKey: "libraryFolder") }
    }

    /// Indexes .ipa files in `folder` and its immediate subfolders, reusing
    /// cached results for files that haven't changed.
    static func scan(_ folder: URL, log: @escaping @Sendable (String) -> Void) async -> [LibraryEntry] {
        let fm = FileManager.default
        var cache: [String: LibraryEntry] = [:]
        if let data = try? Data(contentsOf: cacheURL),
           let entries = try? JSONDecoder().decode([LibraryEntry].self, from: data) {
            cache = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        }

        var files: [URL] = []
        let top = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                               options: [.skipsHiddenFiles])) ?? []
        for url in top {
            if url.pathExtension.lowercased() == "ipa" {
                files.append(url)
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                      url.pathExtension.isEmpty {
                let inner = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
                files += inner.filter { $0.pathExtension.lowercased() == "ipa" }
            }
        }

        var result: [LibraryEntry] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let cached = cache[file.path], cached.modified == modified {
                result.append(cached)
                continue
            }
            guard let info = try? await Signer.inspect(file), !info.bundleID.isEmpty else {
                log("Skipped \(file.lastPathComponent): couldn't read it as an IPA.")
                continue
            }
            result.append(LibraryEntry(path: file.path, bundleID: info.bundleID, name: info.displayName,
                                       version: info.version, modified: modified))
        }

        var merged = cache
        for entry in result { merged[entry.path] = entry }
        if let data = try? JSONEncoder().encode(Array(merged.values)) { try? data.write(to: cacheURL) }
        return result
    }

    // MARK: Install ledger

    /// Remembers which IPA each bundle ID was installed from.
    static func recordInstall(bundleID: String, ipa: URL) {
        var ledger = loadLedger()
        ledger[bundleID] = ipa.path
        if let data = try? JSONEncoder().encode(ledger) { try? data.write(to: ledgerURL) }
    }

    static func loadLedger() -> [String: String] {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return ledger
    }

    /// The IPA an installed bundle ID came from: IPA Courier's own record
    /// first, else a library IPA whose ID matches exactly or with a
    /// sideloader's `.TEAMID` suffix.
    static func source(for installedID: String, entries: [LibraryEntry], ledger: [String: String]) -> LibraryEntry? {
        if let path = ledger[installedID], FileManager.default.fileExists(atPath: path) {
            return entries.first { $0.path == path }
                ?? LibraryEntry(path: path, bundleID: installedID,
                                name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                                version: "", modified: .distantPast)
        }
        let candidates = entries.filter { entry in
            if entry.bundleID == installedID { return true }
            guard installedID.hasPrefix(entry.bundleID + ".") else { return false }
            let suffix = installedID.dropFirst(entry.bundleID.count + 1)
            return suffix.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil
        }
        // Newest file wins when several versions of the same app are present.
        return candidates.max { $0.modified < $1.modified }
    }
}
