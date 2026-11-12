import CryptoKit
import Foundation
import Security

enum AppPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IPA Courier", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var profiles: URL {
        let url = support.appendingPathComponent("Profiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var jobs: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IPA Courier/Jobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// App ID capabilities that big game ports and emulators commonly need.
/// They can't be granted by a wildcard profile, only by one made for the
/// app's exact bundle ID with the capability turned on.
enum Capability: String, CaseIterable, Identifiable, Codable, Hashable {
    case increasedMemoryLimit = "com.apple.developer.kernel.increased-memory-limit"
    case extendedVirtualAddressing = "com.apple.developer.kernel.extended-virtual-addressing"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .increasedMemoryLimit: return "Increased Memory Limit"
        case .extendedVirtualAddressing: return "Extended Virtual Addressing"
        }
    }

    var shortTitle: String {
        switch self {
        case .increasedMemoryLimit: return "More RAM"
        case .extendedVirtualAddressing: return "Extended VA"
        }
    }

    var explanation: String {
        switch self {
        case .increasedMemoryLimit: return "Lets the app use more memory before iOS terminates it."
        case .extendedVirtualAddressing: return "Gives the app a larger address space (used by some emulators and JITs)."
        }
    }

    static func present(in entitlements: [String: Any]) -> Set<Capability> {
        Set(allCases.filter { (entitlements[$0.rawValue] as? Bool) == true })
    }

    static func summary(_ set: Set<Capability>) -> String {
        allCases.filter(set.contains).map(\.title).joined(separator: " + ")
    }
}

struct SigningIdentity: Identifiable, Hashable {
    let sha1: String
    let name: String
    var id: String { sha1 }
}

struct DevTeam: Identifiable, Hashable {
    let id: String
    let name: String
    var label: String { name.isEmpty ? id : "\(name) (\(id))" }
}

struct ProvisioningProfile: Identifiable {
    let uuid: String
    let name: String
    let teamID: String
    let teamName: String
    /// The App ID without the team prefix, e.g. `*` or `com.example.app`.
    let appIDPattern: String
    let expiration: Date
    let devices: Set<String>
    let provisionsAllDevices: Bool
    let certificateSHA1s: Set<String>
    let entitlements: [String: Any]
    let fileURL: URL

    var id: String { uuid }
    var isWildcard: Bool { appIDPattern.hasSuffix("*") }
    var capabilities: Set<Capability> { Capability.present(in: entitlements) }

    func matches(bundleID: String) -> Bool {
        if isWildcard { return bundleID.hasPrefix(String(appIDPattern.dropLast())) }
        return appIDPattern == bundleID
    }

    func includes(udid: String) -> Bool {
        provisionsAllDevices || devices.contains(udid.uppercased())
    }

    /// Exact App IDs beat narrow wildcards, which beat `*`.
    var specificity: Int { isWildcard ? appIDPattern.count - 1 : 100_000 }
}

struct SigningPlan {
    let profile: ProvisioningProfile
    let identity: SigningIdentity
}

enum ProvisioningError: LocalizedError {
    case noTeam
    case stubMissing
    case stillNoProfile(String)

    var errorDescription: String? {
        switch self {
        case .noTeam:
            return "No developer team found. Sign in to Xcode → Settings → Accounts with your Apple Developer account."
        case .stubMissing:
            return "The provisioning helper project is missing from the app bundle."
        case .stillNoProfile(let detail):
            return "Xcode couldn't produce a usable provisioning profile. \(detail)"
        }
    }
}

enum Provisioning {
    static var profileDirectories: [URL] {
        [
            AppPaths.home.appendingPathComponent("Library/Developer/Xcode/UserData/Provisioning Profiles"),
            AppPaths.home.appendingPathComponent("Library/MobileDevice/Provisioning Profiles"),
            AppPaths.profiles,
        ]
    }

    // MARK: Profiles

    static func loadProfiles() -> [ProvisioningProfile] {
        var seen = Set<String>()
        var result: [ProvisioningProfile] = []
        for directory in profileDirectories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where ["mobileprovision", "provisionprofile"].contains(file.pathExtension) {
                guard let profile = parseProfile(at: file), seen.insert(profile.uuid).inserted else { continue }
                result.append(profile)
            }
        }
        return result
    }

    static func parseProfile(at url: URL) -> ProvisioningProfile? {
        guard let data = try? Data(contentsOf: url),
              let content = decodeCMS(data),
              let plist = (try? PropertyListSerialization.propertyList(from: content, format: nil)) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let appID = entitlements["application-identifier"] as? String,
              let uuid = plist["UUID"] as? String
        else { return nil }

        let platforms = plist["Platform"] as? [String] ?? ["iOS"]
        guard platforms.contains("iOS") else { return nil }

        let teamID = (plist["TeamIdentifier"] as? [String])?.first
            ?? String(appID.split(separator: ".").first ?? "")
        let pattern = appID.hasPrefix(teamID + ".") ? String(appID.dropFirst(teamID.count + 1)) : appID
        let certificates = (plist["DeveloperCertificates"] as? [Data] ?? []).map(sha1Hex)

        return ProvisioningProfile(
            uuid: uuid,
            name: plist["Name"] as? String ?? uuid,
            teamID: teamID,
            teamName: plist["TeamName"] as? String ?? "",
            appIDPattern: pattern,
            expiration: plist["ExpirationDate"] as? Date ?? .distantPast,
            devices: Set((plist["ProvisionedDevices"] as? [String] ?? []).map { $0.uppercased() }),
            provisionsAllDevices: plist["ProvisionsAllDevices"] as? Bool ?? false,
            certificateSHA1s: Set(certificates),
            entitlements: entitlements,
            fileURL: url
        )
    }

    private static func decodeCMS(_ data: Data) -> Data? {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }
        let updated = data.withUnsafeBytes { buffer in
            CMSDecoderUpdateMessage(decoder, buffer.baseAddress!, buffer.count)
        }
        guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else { return nil }
        return content as Data
    }

    private static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    // MARK: Identities and teams

    static func loadIdentities() async -> [SigningIdentity] {
        guard let result = try? await Shell.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"]) else {
            return []
        }
        let regex = try! NSRegularExpression(pattern: #"^\s*\d+\)\s+([0-9A-F]{40})\s+"(.+)"\s*$"#)
        return result.text.split(whereSeparator: \.isNewline).compactMap { line in
            let line = String(line)
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let hash = Range(match.range(at: 1), in: line),
                  let name = Range(match.range(at: 2), in: line)
            else { return nil }
            return SigningIdentity(sha1: String(line[hash]), name: String(line[name]))
        }
    }

    /// Teams from the accounts signed in to Xcode, plus any found in profiles.
    static func loadTeams(profiles: [ProvisioningProfile]) -> [DevTeam] {
        var teams: [String: DevTeam] = [:]
        if let byAccount = UserDefaults(suiteName: "com.apple.dt.Xcode")?
            .dictionary(forKey: "IDEProvisioningTeamByIdentifier") as? [String: [[String: Any]]] {
            for entries in byAccount.values {
                for entry in entries {
                    guard let id = entry["teamID"] as? String else { continue }
                    teams[id] = DevTeam(id: id, name: entry["teamName"] as? String ?? "")
                }
            }
        }
        for profile in profiles where teams[profile.teamID] == nil && profile.expiration > Date() {
            teams[profile.teamID] = DevTeam(id: profile.teamID, name: profile.teamName)
        }
        return teams.values.sorted { $0.label < $1.label }
    }

    // MARK: Matching

    static func plan(
        bundleID: String,
        udid: String,
        team: String?,
        capabilities: Set<Capability> = [],
        profiles: [ProvisioningProfile],
        identities: [SigningIdentity]
    ) -> SigningPlan? {
        let byHash = Dictionary(identities.map { ($0.sha1, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date().addingTimeInterval(60 * 60)
        let plans: [SigningPlan] = profiles.compactMap { profile in
            guard profile.expiration > now,
                  profile.includes(udid: udid),
                  profile.matches(bundleID: bundleID),
                  team == nil || profile.teamID == team,
                  capabilities.isSubset(of: profile.capabilities),
                  let identity = profile.certificateSHA1s.compactMap({ byHash[$0] }).first
            else { return nil }
            return SigningPlan(profile: profile, identity: identity)
        }
        return plans.max { a, b in
            (a.profile.specificity, a.profile.expiration) < (b.profile.specificity, b.profile.expiration)
        }
    }

    // MARK: Asking Xcode for a profile

    /// Builds (never installs) a tiny placeholder app for the device with
    /// automatic signing, which makes Xcode create a development certificate
    /// if needed, register the device, and download a matching profile.
    /// With `capabilities`, Xcode registers (or updates) an explicit App ID
    /// for `bundleID` with those capabilities and makes a profile for it.
    static func refreshWithXcode(
        teamID: String,
        udid: String,
        bundleID: String,
        capabilities: Set<Capability> = [],
        log: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let stub = Bundle.main.url(forResource: "ProvisioningStub", withExtension: nil) else {
            throw ProvisioningError.stubMissing
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipa-courier-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: stub, to: work)
        defer { try? FileManager.default.removeItem(at: work) }

        let derived = work.appendingPathComponent("DerivedData")
        var extraSettings: [String] = []
        if capabilities.isEmpty {
            log("Asking Xcode to register the device and fetch a profile for team \(teamID)…")
        } else {
            let entitlementsURL = work.appendingPathComponent("Stub.entitlements")
            let entitlements = Dictionary(uniqueKeysWithValues: capabilities.map { ($0.rawValue, true) })
            try PropertyListSerialization.data(fromPropertyList: entitlements, format: .xml, options: 0)
                .write(to: entitlementsURL)
            extraSettings.append("CODE_SIGN_ENTITLEMENTS=\(entitlementsURL.path)")
            log("Asking Xcode for a \(bundleID) profile with \(Capability.summary(capabilities)) (team \(teamID))…")
        }
        let interesting = ["error", "warning:", "Signing Identity", "Provisioning Profile", "BUILD"]
        try await Shell.run("/usr/bin/xcrun", [
            "xcodebuild",
            "-project", work.appendingPathComponent("Stub.xcodeproj").path,
            "-scheme", "Stub",
            "-configuration", "Debug",
            "-destination", "id=\(udid)",
            "-derivedDataPath", derived.path,
            "-allowProvisioningUpdates",
            "-allowProvisioningDeviceRegistration",
            "DEVELOPMENT_TEAM=\(teamID)",
            "PRODUCT_BUNDLE_IDENTIFIER=\(bundleID)",
            "CODE_SIGN_STYLE=Automatic",
        ] + extraSettings + ["build"], onOutput: { chunk in
            for line in chunk.split(whereSeparator: \.isNewline)
            where interesting.contains(where: { line.contains($0) }) {
                log(String(line).trimmingCharacters(in: .whitespaces))
            }
        })

        let embedded = derived.appendingPathComponent("Build/Products/Debug-iphoneos/Stub.app/embedded.mobileprovision")
        guard let profile = parseProfile(at: embedded) else {
            throw ProvisioningError.stillNoProfile("The build finished without an embedded profile.")
        }
        let destination = AppPaths.profiles.appendingPathComponent("\(profile.uuid).mobileprovision")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: embedded, to: destination)
        log("Got profile “\(profile.name)”, valid until \(profile.expiration.formatted(date: .abbreviated, time: .omitted)).")
    }
}
