import Foundation

enum InstallError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let detail): return detail
        }
    }
}

struct InstalledApp: Equatable {
    let bundleID: String
    let name: String
    let version: String
    /// Signed with a development certificate (sideloaded), not from the App Store.
    var builtByDeveloper = false
}

/// How an IPA relates to what's already on the device.
struct ExistingInstall: Equatable {
    let app: InstalledApp
    /// The team ID a sideloading tool appended (e.g. Sideloadly's `.ABCDE12345`), if any.
    let teamSuffix: String?
    /// Another copy under a different ID that won't be touched.
    let otherCopy: InstalledApp?

    /// Picks the installed copy an IPA should update. Prefers the copy with
    /// a team ID suffix (what Sideloadly installs), ideally from `preferredTeams`.
    static func find(for bundleID: String, in apps: [InstalledApp], preferredTeams: [String]) -> ExistingInstall? {
        let exact = apps.first { $0.bundleID == bundleID }
        let suffixed: [(InstalledApp, String)] = apps.compactMap { app in
            guard app.bundleID.hasPrefix(bundleID + ".") else { return nil }
            let suffix = String(app.bundleID.dropFirst(bundleID.count + 1))
            guard suffix.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
            return (app, suffix)
        }
        let pick = suffixed.first { preferredTeams.contains($0.1) } ?? suffixed.first
        if let (app, suffix) = pick {
            return ExistingInstall(app: app, teamSuffix: suffix, otherCopy: exact)
        }
        if let exact {
            return ExistingInstall(app: exact, teamSuffix: nil, otherCopy: nil)
        }
        return nil
    }
}

enum Installer {
    /// Lists the user-installed apps on the device.
    static func installedApps(udid: String) async throws -> [InstalledApp] {
        let result = try await Shell.run("/usr/bin/xcrun", [
            "devicectl", "device", "info", "apps", "--device", udid, "--json-output", "-",
        ], mergeStderr: false)
        guard let json = try JSONSerialization.jsonObject(with: result.output) as? [String: Any],
              let apps = (json["result"] as? [String: Any])?["apps"] as? [[String: Any]]
        else { return [] }
        return apps.compactMap { app in
            guard let id = app["bundleIdentifier"] as? String else { return nil }
            return InstalledApp(bundleID: id,
                                name: app["name"] as? String ?? id,
                                version: app["version"] as? String ?? "",
                                builtByDeveloper: app["builtByDeveloper"] as? Bool ?? false)
        }
    }

    /// Installs a signed .app with `devicectl`, reporting its percentage.
    /// Runs under `script` so devicectl sees a terminal and prints live progress.
    static func install(
        app: URL,
        udid: String,
        progress: @escaping @Sendable (Double?, String) -> Void,
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        let parser = ProgressParser()
        let result = try await Shell.run("/usr/bin/script", [
            "-q", "/dev/null",
            "/usr/bin/xcrun", "devicectl", "device", "install", "app",
            "--device", udid, app.path,
        ], checkStatus: false, onOutput: { chunk in
            let update = parser.feed(chunk)
            if let percent = update.percent { progress(percent / 100, update.status ?? "Copying to device") }
            else if let status = update.status { progress(nil, status) }
            for line in update.logLines { log(line) }
        })

        let output = ProgressParser.clean(result.text)
        if result.status != 0 || output.contains("ERROR:") || !output.contains("App installed") {
            throw InstallError.failed(friendlyError(from: output, status: result.status))
        }
        progress(1, "Installed")
    }

    private static func friendlyError(from output: String, status: Int32) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let reason = lines.first(where: { $0.hasPrefix("NSLocalizedFailureReason") }) {
            return reason.replacingOccurrences(of: "NSLocalizedFailureReason = ", with: "")
        }
        if let error = lines.first(where: { $0.hasPrefix("ERROR:") }) {
            return error.replacingOccurrences(of: "ERROR: ", with: "")
        }
        return "devicectl exited with status \(status).\n" + lines.suffix(10).joined(separator: "\n")
    }
}

/// Pulls percentages and status lines out of devicectl's terminal output.
final class ProgressParser: @unchecked Sendable {
    struct Update {
        var percent: Double?
        var status: String?
        var logLines: [String] = []
    }

    private let lock = NSLock()
    private var pending = ""
    private let percentRegex = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d+)?)\s?%"#)

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\e\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\e[()][0-9A-Za-z]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}", with: "")
    }

    func feed(_ chunk: String) -> Update {
        lock.lock(); defer { lock.unlock() }
        var update = Update()
        pending += Self.clean(chunk)
        // Progress redraws with carriage returns, so treat \r like \n.
        var pieces = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        pending = pieces.removeLast()
        for piece in pieces + [pending] {
            let line = piece.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..., in: line)
            if let match = percentRegex.matches(in: line, range: range).last,
               let numberRange = Range(match.range(at: 1), in: line),
               let value = Double(line[numberRange]), value <= 100 {
                update.percent = value
                let label = line.replacingCharacters(in: Range(match.range, in: line)!, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " .:-"))
                if !label.isEmpty, label.count < 80 { update.status = label }
            } else if piece != pending {
                update.status = line.count < 100 ? line : String(line.prefix(100)) + "…"
                update.logLines.append(line)
            }
        }
        return update
    }
}
