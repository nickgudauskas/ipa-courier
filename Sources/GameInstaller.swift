import Foundation

enum GameInstallError: LocalizedError {
    case download(String)
    case nothingFound(String)

    var errorDescription: String? {
        switch self {
        case .download(let detail): return "The download failed: \(detail)"
        case .nothingFound(let detail): return detail
        }
    }
}

/// Reports download progress for one task.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Int64, Int64) -> Void
    init(_ onProgress: @escaping @Sendable (Int64, Int64) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

struct InstalledMacGame {
    let url: URL
    /// Every app installed, including helpers such as a configuration tool.
    let allApps: [URL]
    let notarized: Bool
}

enum GameInstaller {
    static var gamesFolder: URL {
        let url = AppPaths.home.appendingPathComponent("Applications/Games", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var workFolder: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IPA Courier/Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Download

    /// Downloads `asset` into `directory`, reporting a 0–1 fraction.
    static func download(_ asset: ReleaseAsset, into directory: URL,
                         progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        let reporter = DownloadProgress { written, expected in
            let total = expected > 0 ? expected : asset.size
            let fraction = total > 0 ? min(Double(written) / Double(total), 1) : 0
            progress(fraction, "\(ByteFormat.string(written)) of \(ByteFormat.string(total))")
        }
        var request = URLRequest(url: asset.downloadURL)
        request.setValue("IPA-Courier", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request, delegate: reporter)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw GameInstallError.download("HTTP \(http.statusCode)")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(asset.name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    // MARK: Unpacking

    static func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return [".zip", ".dmg", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2"].contains(where: name.hasSuffix)
    }

    /// Extracts an archive into `directory`.
    static func extract(_ archive: URL, into directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = archive.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") {
            try await Shell.run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        } else if name.hasSuffix(".dmg") {
            let mount = FileManager.default.temporaryDirectory
                .appendingPathComponent("ipa-courier-dmg-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            try await Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                     "-mountpoint", mount.path, archive.path])
            func eject() async {
                _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", "-force", mount.path], checkStatus: false)
                try? FileManager.default.removeItem(at: mount)
            }
            do {
                let items = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
                for item in items where item.lastPathComponent != "Applications" && !item.lastPathComponent.hasPrefix(".") {
                    try await Shell.run("/usr/bin/ditto", [item.path, directory.appendingPathComponent(item.lastPathComponent).path])
                }
            } catch {
                await eject()
                throw error
            }
            await eject()
        } else {
            try await Shell.run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path])
        }
    }

    /// Items with `extension` in `folder`, shallowest first, not inside another bundle.
    static func find(_ ext: String, in folder: URL, maxDepth: Int = 5) -> [URL] {
        var found: [URL] = []
        func walk(_ url: URL, depth: Int) {
            guard depth <= maxDepth,
                  let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                           options: [.skipsHiddenFiles]) else { return }
            for item in items {
                if item.pathExtension.lowercased() == ext {
                    found.append(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          !["app", "framework", "bundle"].contains(item.pathExtension.lowercased()) {
                    walk(item, depth: depth + 1)
                }
            }
        }
        walk(folder, depth: 0)
        return found.sorted { $0.pathComponents.count < $1.pathComponents.count }
    }

    /// Extracts, then keeps extracting nested archives until `ext` items appear (up to 3 levels).
    static func unpack(_ archive: URL, lookingFor ext: String, into folder: URL) async throws -> [URL] {
        try await extract(archive, into: folder)
        for _ in 0..<3 {
            let hits = find(ext, in: folder)
            if !hits.isEmpty { return hits }
            let nested = find("zip", in: folder) + find("dmg", in: folder)
                + find("gz", in: folder) + find("xz", in: folder) + find("tar", in: folder)
            guard let inner = nested.first(where: isArchive) else { break }
            let target = inner.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
            try await extract(inner, into: target)
            try? FileManager.default.removeItem(at: inner)
        }
        return find(ext, in: folder)
    }

    // MARK: Mac install

    /// Installs a downloaded Mac build into ~/Applications/Games and reports whether Apple notarized it.
    static func installMac(_ archive: URL, project: CatalogProject,
                           status: @escaping @Sendable (String) -> Void) async throws -> InstalledMacGame {
        let fm = FileManager.default
        let unpacked = archive.deletingLastPathComponent().appendingPathComponent("unpacked", isDirectory: true)
        try? fm.removeItem(at: unpacked)
        status("Unpacking \(archive.lastPathComponent)…")
        let apps = try await unpack(archive, lookingFor: "app", into: unpacked)

        let destination: URL
        var installedApps: [URL] = []
        if !apps.isEmpty {
            // Install every app at the top level (e.g. a game plus its configuration tool);
            // the main one is the app that isn't a helper.
            let depth = apps[0].pathComponents.count
            let topLevel = apps.filter { $0.pathComponents.count == depth }
            let helperWords = ["configure", "config", "setup", "uninstall", "launcher settings"]
            let main = topLevel.first { app in
                !helperWords.contains { app.lastPathComponent.lowercased().contains($0) }
            } ?? topLevel[0]
            for app in topLevel {
                let target = gamesFolder.appendingPathComponent(app.lastPathComponent)
                status("Installing \(app.lastPathComponent)…")
                if fm.fileExists(atPath: target.path) { try fm.trashItem(at: target, resultingItemURL: nil) }
                try await Shell.run("/usr/bin/ditto", [app.path, target.path])
                installedApps.append(target)
            }
            destination = gamesFolder.appendingPathComponent(main.lastPathComponent)
        } else {
            // No .app bundle (e.g. a command-line build): install the whole folder.
            let contents = (try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            guard !contents.isEmpty else {
                throw GameInstallError.nothingFound("The download didn't contain anything to install.")
            }
            let root = contents.count == 1 ? contents[0] : unpacked
            destination = gamesFolder.appendingPathComponent(project.name, isDirectory: true)
            status("Installing to \(destination.lastPathComponent)…")
            if fm.fileExists(atPath: destination.path) { try fm.trashItem(at: destination, resultingItemURL: nil) }
            try await Shell.run("/usr/bin/ditto", [root.path, destination.path])
        }
        try? fm.removeItem(at: unpacked)

        status("Checking signature…")
        let notarized = destination.pathExtension == "app"
            ? ((try? await Shell.run("/usr/sbin/spctl", ["--assess", "--type", "execute", destination.path],
                                     checkStatus: false))?.status == 0)
            : false
        return InstalledMacGame(url: destination, allApps: installedApps, notarized: notarized)
    }

    /// Adds or removes macOS's download quarantine on an installed game.
    /// With quarantine, Gatekeeper checks the app on first open as it would for a browser download.
    static func setQuarantine(_ on: Bool, at url: URL) async {
        if on {
            let value = String(format: "0081;%08x;IPA Courier;", Int(Date().timeIntervalSince1970))
            _ = try? await Shell.run("/usr/bin/xattr", ["-w", "com.apple.quarantine", value, url.path], checkStatus: false)
        } else {
            _ = try? await Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path], checkStatus: false)
        }
    }

    // MARK: iOS download

    /// Downloads an iOS build and returns the .ipa, unpacking it from a zip if needed.
    static func downloadIPA(_ asset: ReleaseAsset, to folder: URL, work: URL,
                            progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        let file = try await download(asset, into: work, progress: progress)
        let ipa: URL
        if file.pathExtension.lowercased() == "ipa" {
            ipa = file
        } else {
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            guard let found = try await unpack(file, lookingFor: "ipa", into: unpacked).first else {
                throw GameInstallError.nothingFound("\(asset.name) doesn't contain an .ipa file.")
            }
            ipa = found
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(ipa.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: ipa, to: destination)
        return destination
    }
}
