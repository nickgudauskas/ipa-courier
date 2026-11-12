import Foundation

struct IPAInspection: Equatable {
    let url: URL
    let entryCount: Int
    let uncompressedBytes: Int64
    let bundleID: String
    let displayName: String
    let version: String
    let minimumOS: String?
}

enum SignerError: LocalizedError {
    case notAnIPA(String)
    case noApp
    case verifyFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAnIPA(let detail): return "That doesn't look like an iOS app archive. \(detail)"
        case .noApp: return "No Payload/*.app folder was found in the IPA."
        case .verifyFailed(let detail): return "The signature didn't verify: \(detail)"
        }
    }
}

enum Signer {
    // MARK: Inspect

    static func inspect(_ url: URL) async throws -> IPAInspection {
        let totals = try await Shell.run("/usr/bin/zipinfo", ["-t", url.path])
        let regex = try! NSRegularExpression(pattern: #"(\d+) files?, (\d+) bytes uncompressed"#)
        let text = totals.text
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let countRange = Range(match.range(at: 1), in: text),
              let bytesRange = Range(match.range(at: 2), in: text)
        else { throw SignerError.notAnIPA(text.trimmingCharacters(in: .whitespacesAndNewlines)) }

        let listing = try await Shell.run("/usr/bin/zipinfo", ["-1", url.path])
        guard let infoPath = listing.text.split(whereSeparator: \.isNewline).first(where: { line in
            line.hasPrefix("Payload/") && line.hasSuffix(".app/Info.plist")
                && line.split(separator: "/").count == 3
        }) else { throw SignerError.noApp }

        let plistData = try await Shell.run("/usr/bin/unzip", ["-p", url.path, String(infoPath)], mergeStderr: false).output
        let plist = (try? PropertyListSerialization.propertyList(from: plistData, format: nil)) as? [String: Any] ?? [:]
        let bundleID = plist["CFBundleIdentifier"] as? String ?? ""
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return IPAInspection(
            url: url,
            entryCount: Int(text[countRange]) ?? 0,
            uncompressedBytes: Int64(text[bytesRange]) ?? 0,
            bundleID: bundleID,
            displayName: name,
            version: plist["CFBundleShortVersionString"] as? String ?? plist["CFBundleVersion"] as? String ?? "?",
            minimumOS: plist["MinimumOSVersion"] as? String
        )
    }

    // MARK: Unpack

    /// Extracts the IPA, reporting progress by bytes written.
    static func unpack(
        _ ipa: IPAInspection,
        into directory: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> URL {
        let sizes = try await entrySizes(ipa.url)
        let tracker = UnzipTracker(root: directory, sizes: sizes, total: max(ipa.uncompressedBytes, 1))

        let poller = Task {
            while !Task.isCancelled {
                let (fraction, file) = tracker.snapshot()
                progress(fraction, file)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { poller.cancel() }

        try await Shell.run("/usr/bin/unzip", ["-o", ipa.url.path, "-d", directory.path],
                            onOutput: { tracker.feed($0) })
        progress(1, "")

        let payload = directory.appendingPathComponent("Payload")
        let apps = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: { $0.pathExtension == "app" }) else { throw SignerError.noApp }
        return app
    }

    private static func entrySizes(_ url: URL) async throws -> [String: Int64] {
        let listing = try await Shell.run("/usr/bin/unzip", ["-l", url.path])
        let regex = try! NSRegularExpression(pattern: #"^\s*(\d+)\s+\S+\s+\S+\s+(.+)$"#)
        var sizes: [String: Int64] = [:]
        for line in listing.text.split(whereSeparator: \.isNewline) {
            let line = String(line)
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let sizeRange = Range(match.range(at: 1), in: line),
                  let nameRange = Range(match.range(at: 2), in: line)
            else { continue }
            sizes[String(line[nameRange])] = Int64(line[sizeRange])
        }
        return sizes
    }

    static func directorySize(_ url: URL) async -> Int64 {
        guard let result = try? await Shell.run("/usr/bin/du", ["-sk", url.path]),
              let kb = Int64(result.text.split(separator: "\t").first ?? "")
        else { return 0 }
        return kb * 1024
    }

    // MARK: Sign

    static func sign(
        app: URL,
        bundleID newBundleID: String,
        plan: SigningPlan,
        log: @escaping @Sendable (String) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) async throws {
        let fm = FileManager.default
        let infoURL = app.appendingPathComponent("Info.plist")
        let oldBundleID = (NSDictionary(contentsOf: infoURL)?["CFBundleIdentifier"] as? String) ?? newBundleID

        // Watch apps need their own provisioning and can't be installed this way.
        for name in ["Watch", "com.apple.WatchPlaceholder"] {
            let url = app.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
                log("Removed \(name) (Apple Watch apps aren't supported).")
            }
        }

        // Nested code is signed deepest first, so outer signatures seal inner ones.
        let nested = nestedCode(in: app)

        let workDir = app.deletingLastPathComponent().deletingLastPathComponent()
        var signedCount = 0
        let total = nested.count + 1

        for url in nested {
            signedCount += 1
            status("Signing \(url.lastPathComponent) (\(signedCount)/\(total))")
            let isBundleWithProfile = ["appex", "app"].contains(url.pathExtension)
            if isBundleWithProfile {
                let plistURL = url.appendingPathComponent("Info.plist")
                let id = try rewriteBundleID(at: plistURL, old: oldBundleID, new: newBundleID)
                try embedProfile(plan.profile, in: url)
                let entitlementsURL = try writeEntitlements(plan: plan, bundleID: id, into: workDir)
                try await codesign(url, identity: plan.identity, entitlements: entitlementsURL)
            } else {
                try await codesign(url, identity: plan.identity, entitlements: nil)
            }
            log("Signed \(url.lastPathComponent)")
        }

        status("Signing \(app.lastPathComponent) (\(total)/\(total)) — hashing every resource, this can take a while")
        _ = try rewriteBundleID(at: infoURL, old: oldBundleID, new: newBundleID)
        try stripSupportedDevices(at: infoURL)
        try embedProfile(plan.profile, in: app)
        let entitlementsURL = try writeEntitlements(plan: plan, bundleID: newBundleID, into: workDir)
        try await codesign(app, identity: plan.identity, entitlements: entitlementsURL)
        log("Signed \(app.lastPathComponent) as \(newBundleID) with “\(plan.identity.name)”.")

        status("Verifying signature")
        do {
            try await Shell.run("/usr/bin/codesign", ["--verify", "--strict", app.path])
        } catch let error as CommandError {
            throw SignerError.verifyFailed(error.output)
        }
        log("Signature verified.")
    }

    private static func nestedCode(in app: URL) -> [URL] {
        var nested: [URL] = []
        if let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) {
            while let url = walker.nextObject() as? URL {
                if ["framework", "appex", "app", "xpc", "dylib"].contains(url.pathExtension) {
                    nested.append(url)
                }
            }
        }
        return nested.sorted { $0.pathComponents.count > $1.pathComponents.count }
    }

    private static func codesign(_ url: URL, identity: SigningIdentity, entitlements: URL?) async throws {
        var arguments = ["--force", "--sign", identity.sha1, "--timestamp=none", "--generate-entitlement-der"]
        if let entitlements { arguments += ["--entitlements", entitlements.path] }
        arguments.append(url.path)
        try await Shell.run("/usr/bin/codesign", arguments)
    }

    private static func embedProfile(_ profile: ProvisioningProfile, in bundle: URL) throws {
        let destination = bundle.appendingPathComponent("embedded.mobileprovision")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: profile.fileURL, to: destination)
    }

    /// Changes the bundle ID (and any nested IDs that share its prefix). Returns the resulting ID.
    private static func rewriteBundleID(at plistURL: URL, old: String, new: String) throws -> String {
        guard let plist = NSMutableDictionary(contentsOf: plistURL),
              let current = plist["CFBundleIdentifier"] as? String
        else { return new }
        guard old != new, current.hasPrefix(old) else { return current }
        let updated = new + current.dropFirst(old.count)
        plist["CFBundleIdentifier"] = updated
        try plist.write(to: plistURL)
        return updated
    }

    /// Some re-packaged apps restrict themselves to particular device models.
    private static func stripSupportedDevices(at plistURL: URL) throws {
        guard let plist = NSMutableDictionary(contentsOf: plistURL), plist["UISupportedDevices"] != nil else { return }
        plist.removeObject(forKey: "UISupportedDevices")
        try plist.write(to: plistURL)
    }

    private static func writeEntitlements(plan: SigningPlan, bundleID: String, into directory: URL) throws -> URL {
        let team = plan.profile.teamID
        var entitlements = plan.profile.entitlements
        entitlements["application-identifier"] = "\(team).\(bundleID)"
        entitlements["com.apple.developer.team-identifier"] = team
        if entitlements["keychain-access-groups"] != nil {
            entitlements["keychain-access-groups"] = ["\(team).\(bundleID)"]
        }
        // Drop any remaining wildcard values; they're only valid inside profiles.
        for (key, value) in entitlements {
            if let string = value as? String, string.contains("*") { entitlements.removeValue(forKey: key) }
            if let array = value as? [String], array.contains(where: { $0.contains("*") }) {
                entitlements.removeValue(forKey: key)
            }
        }
        let url = directory.appendingPathComponent("entitlements-\(bundleID).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    // MARK: Export

    /// Zips Payload/ back into an .ipa.
    static func exportIPA(jobDirectory: URL, to destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)
        try await Shell.run("/usr/bin/ditto", [
            "-c", "-k", "--sequesterRsrc", "--keepParent",
            jobDirectory.appendingPathComponent("Payload").path,
            destination.path,
        ])
    }
}

/// Turns unzip's "  inflating: <path>" stream into byte progress.
/// unzip prints a file's name before writing it, so the current file's
/// on-disk size gives progress within very large files too.
final class UnzipTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let rootPrefix: String
    private let sizes: [String: Int64]
    private let total: Int64
    private var completed: Int64 = 0
    private var current: (path: String, size: Int64)?
    private var pending = ""

    init(root: URL, sizes: [String: Int64], total: Int64) {
        self.rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        self.sizes = sizes
        self.total = total
    }

    func feed(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        pending += chunk
        // Parse every marker we can see, including a final line whose newline hasn't arrived yet.
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        for line in lines { consume(line, finished: true) }
        consumePartial()
    }

    private var lastPartial = ""

    private func consumePartial() {
        guard !pending.isEmpty, pending != lastPartial else { return }
        lastPartial = pending
        consume(pending, finished: false)
    }

    private func consume(_ line: String, finished: Bool) {
        if finished && line == lastPartial {
            lastPartial = ""
            return // already counted when it arrived without its newline
        }
        for marker in ["inflating: ", "extracting: ", "creating: ", "linking: "] {
            guard let range = line.range(of: marker) else { continue }
            var path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if marker == "linking: ", let arrow = path.range(of: " -> ") { path = String(path[..<arrow.lowerBound]) }
            let relative = path.hasPrefix(rootPrefix) ? String(path.dropFirst(rootPrefix.count)) : path
            if let current { completed += current.size }
            current = (path, sizes[relative] ?? 0)
            return
        }
    }

    func snapshot() -> (Double, String) {
        lock.lock()
        let done = completed
        let file = current
        lock.unlock()
        var partial: Int64 = 0
        if let file, file.size > 0,
           let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let size = attributes[.size] as? NSNumber {
            partial = min(size.int64Value, file.size)
        }
        let fraction = min(Double(done + partial) / Double(total), 1)
        return (fraction, file.map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "")
    }
}
