import AppKit
import Foundation

enum SelfUpdateError: LocalizedError {
    case noApp(String)
    case verification(String)
    case replace(String)

    var errorDescription: String? {
        switch self {
        case .noApp(let name): return "\(name) doesn't contain IPA Courier."
        case .verification(let detail): return "The downloaded update didn't pass its safety check: \(detail)"
        case .replace(let detail): return "Couldn't replace IPA Courier: \(detail)"
        }
    }
}

/// Replaces the running copy of IPA Courier with a downloaded release and relaunches it.
///
/// Only used when the new copy can be verified against the running one (same Developer ID
/// team and bundle ID, notarized, the announced version) and the app's folder is writable.
/// Anything else falls back to opening the DMG for a manual drag to Applications.
enum SelfUpdater {
    /// The running app, if it can be replaced in place; nil means use the manual DMG flow.
    static func replaceableApp() async -> URL? {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard app.pathExtension == "app",
              !app.path.contains("/AppTranslocation/") else { return nil }  // quarantined copy run from Downloads
        let parent = app.deletingLastPathComponent()
        if (try? parent.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return nil }  // e.g. the DMG
        guard FileManager.default.isWritableFile(atPath: parent.path),
              FileManager.default.isWritableFile(atPath: app.path) else { return nil }
        // Development builds are ad-hoc signed: there's no team to check an update against.
        guard await teamID(of: app) != nil else { return nil }
        return app
    }

    /// The Developer ID team that signed `app`, or nil for unsigned and ad-hoc builds.
    static func teamID(of app: URL) async -> String? {
        guard let result = try? await Shell.run("/usr/bin/codesign", ["-dv", app.path], checkStatus: false),
              result.status == 0 else { return nil }
        let team = result.text.split(separator: "\n")
            .first { $0.hasPrefix("TeamIdentifier=") }?
            .dropFirst("TeamIdentifier=".count)
        guard let team, !team.isEmpty, team != "not set" else { return nil }
        return String(team)
    }

    /// A verified copy of the new version, staged on the same volume as the running app.
    struct Prepared {
        let app: URL
        let folder: URL
        func discard() { try? FileManager.default.removeItem(at: folder) }
    }

    /// Downloads `dmg` and stages the verified app inside it next to `current`. Cancellable.
    /// Nothing about the running app changes until `swap(_:into:)`.
    static func prepare(_ dmg: ReleaseAsset, version: String, for current: URL,
                        status: @escaping @Sendable (Double?, String) -> Void) async throws -> Prepared {
        let fm = FileManager.default
        // A staging folder on the same volume as the app, so the swap is a rename.
        let folder = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                appropriateFor: current, create: true)
        do {
            let file = try await GameInstaller.download(dmg, into: folder.appendingPathComponent("download")) { fraction, text in
                status(fraction, "Downloading · \(text)")
            }
            status(nil, "Checking the download…")
            // extract() mounts at a unique path and always ejects.
            let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
            try await GameInstaller.extract(file, into: unpacked)
            try? fm.removeItem(at: file)
            let apps = (try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "app" } ?? []
            guard let app = apps.first(where: { info($0)?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier })
            else { throw SelfUpdateError.noApp(dmg.name) }
            try Task.checkCancellation()
            try await verify(app, version: version, against: current)
            return Prepared(app: app, folder: folder)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    /// Swaps the staged copy in for `current` in one step. The running process keeps its loaded code.
    static func swap(_ prepared: Prepared, into current: URL) throws {
        defer { prepared.discard() }
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: prepared.app, backupItemName: nil, options: [])
        } catch {
            throw SelfUpdateError.replace(error.localizedDescription)
        }
    }

    /// Starts a helper that opens `app` once this process exits, then quits.
    /// Returns false (and doesn't quit) if the helper couldn't start or quitting was cancelled.
    @MainActor
    static func relaunch(_ app: URL) -> Bool {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait up to an hour for this process to exit, then open the new copy.
        helper.arguments = ["-c", """
            i=0; while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; i=$((i+1)); [ $i -ge 18000 ] && exit 0; done
            /usr/bin/open "$2"
            """, "relaunch", String(ProcessInfo.processInfo.processIdentifier), app.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            return false
        }
        NSApp.terminate(nil)
        return false  // terminate(_:) returns only when quitting was cancelled
    }

    /// Info.plist read straight from disk. Bundle(url:) caches by path for the process's life.
    private static func info(_ app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    // MARK: Checks

    private static func verify(_ candidate: URL, version: String, against current: URL) async throws {
        let candidateVersion = info(candidate)?["CFBundleShortVersionString"] as? String ?? "?"
        guard candidateVersion == version else {
            throw SelfUpdateError.verification("it's version \(candidateVersion), not \(version).")
        }
        try await verifySignature(candidate, against: current)
        let assessment = try await Shell.run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", candidate.path],
                                             checkStatus: false)
        guard assessment.status == 0, assessment.text.contains("Notarized Developer ID") else {
            throw SelfUpdateError.verification("macOS doesn't recognize it as notarized by Apple.")
        }
    }

    /// The copy must be validly signed by the same team, with the same bundle ID, as the running app.
    private static func verifySignature(_ candidate: URL, against current: URL) async throws {
        guard let team = await teamID(of: current), let bundleID = Bundle.main.bundleIdentifier else {
            throw SelfUpdateError.verification("this copy of IPA Courier isn't signed with a Developer ID.")
        }
        let requirement = "=anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
        let result = try await Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", requirement, candidate.path],
                                         checkStatus: false)
        guard result.status == 0 else {
            throw SelfUpdateError.verification("its signature doesn't match this copy's developer (\(team)).")
        }
    }
}
