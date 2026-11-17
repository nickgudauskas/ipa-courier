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

    /// Downloads `dmg`, verifies the app inside, swaps it in for `current` and returns.
    /// Call `relaunch(_:)` afterwards.
    static func install(_ dmg: ReleaseAsset, version: String, replacing current: URL,
                        status: @escaping @Sendable (Double?, String) -> Void) async throws {
        let fm = FileManager.default
        let work = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IPA Courier/Update", isDirectory: true)
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let file = try await GameInstaller.download(dmg, into: work) { fraction, text in
            status(fraction, "Downloading · \(text)")
        }

        status(nil, "Checking the download…")
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try await Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                 "-mountpoint", mount.path, file.path])
        var mounted = true
        func eject() async {
            guard mounted else { return }
            mounted = false
            _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", "-force", mount.path], checkStatus: false)
        }

        // A staging folder on the same volume as the app, so the swap is a rename.
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: current, create: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(current.lastPathComponent, isDirectory: true)

        do {
            let apps = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "app" } ?? []
            guard let candidate = apps.first(where: { Bundle(url: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier })
            else { throw SelfUpdateError.noApp(dmg.name) }
            try await verify(candidate, version: version, against: current)

            status(nil, "Installing \(version)…")
            try await Shell.run("/usr/bin/ditto", [candidate.path, staged.path])
            await eject()
        } catch {
            await eject()
            throw error
        }

        // Check the copy too, then swap it in. The running process keeps its already-loaded code.
        try await verifySignature(staged, against: current)
        do {
            _ = try fm.replaceItemAt(current, withItemAt: staged, backupItemName: nil, options: [])
        } catch {
            throw SelfUpdateError.replace(error.localizedDescription)
        }
    }

    /// Waits for this process to quit, then opens `app`, and quits.
    @MainActor
    static func relaunch(_ app: URL) {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                            "relaunch", String(ProcessInfo.processInfo.processIdentifier), app.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        do {
            try helper.run()
        } catch {
            NSWorkspace.shared.open(app)  // can't wait; macOS will bring the running copy forward instead
        }
        NSApp.terminate(nil)
    }

    // MARK: Checks

    private static func verify(_ candidate: URL, version: String, against current: URL) async throws {
        let info = Bundle(url: candidate)?.infoDictionary
        let candidateVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
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
