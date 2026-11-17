import AppKit
import Foundation
import UserNotifications

enum DiscoverFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case mac = "Mac"
    case ios = "iPhone & iPad"
    case android = "Android"
    case padmint = "PadMint"
    var id: String { rawValue }
}

enum GamePlatform: String {
    case mac, ios, android
}

struct GameJob: Equatable {
    var status: String
    var fraction: Double?
    var error: String?
    var running = true
    /// iOS builds: the IPA that was added to the queue.
    var ipa: URL?
}

struct InstalledGame: Codable, Equatable {
    let tag: String
    let path: String
    let installedAt: Date
}

/// Remembers Mac games installed from the catalog.
private enum InstalledGames {
    static var url: URL { AppPaths.support.appendingPathComponent("installed-games.json") }

    static func load() -> [String: InstalledGame] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: InstalledGame].self, from: data)) ?? [:]
    }

    static func save(_ games: [String: InstalledGame]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(games) { try? data.write(to: url) }
    }
}

@MainActor
final class DiscoverModel: ObservableObject {
    weak var courier: CourierModel?
    weak var android: AndroidModel?

    @Published private(set) var catalog: Catalog?
    @Published private(set) var catalogSource = ""
    @Published private(set) var releases: [String: Release] = [:]
    @Published private(set) var releaseErrors: [String: String] = [:]
    @Published private(set) var loading = false
    @Published private(set) var problem: String?
    @Published var search = ""
    @Published var filter: DiscoverFilter = .all
    /// nil shows every console.
    @Published var console: String?
    @Published var selected: CatalogProject?
    @Published private(set) var jobs: [String: GameJob] = [:]
    @Published private(set) var installed: [String: InstalledGame] = InstalledGames.load()
    @Published private(set) var padMintCommand: URL?
    /// When the published release index was last built.
    @Published private(set) var indexDate: Date?

    private var started = false
    /// Bundle ID → project links, rebuilt when the catalog or the learned IDs change.
    private var linkCache: (key: String, links: [String: CatalogProject])?
    /// Original bundle ID → project ID, learned from IPAs downloaded through Discover.
    @Published private(set) var learnedBundleIDs: [String: String] =
        UserDefaults.standard.dictionary(forKey: "discoverBundleIDs") as? [String: String] ?? [:]

    func loadIfNeeded() {
        guard !started else { return }
        started = true
        Task { await load(force: false) }
    }

    func load(force: Bool) async {
        loading = true
        problem = nil
        let (catalog, source) = await CatalogLoader.load()
        self.catalog = catalog
        catalogSource = source
        guard let catalog else {
            problem = "Couldn't load the game catalog. Check your internet connection and click Refresh."
            loading = false
            return
        }

        var repos = Set(catalog.projects.map(\.repo))
        if let padmint = catalog.padmint { repos.insert(padmint.repo) }

        // One download covers most projects; only ask GitHub's API about the rest,
        // which keeps a large catalog under the 60-requests-per-hour anonymous limit.
        if let index = await ReleaseIndex.load() {
            for repo in repos {
                if let release = index.releases[repo] {
                    releases[repo] = release
                    releaseErrors[repo] = nil
                }
            }
            repos.subtract(index.releases.keys)
            indexDate = index.generatedAt
        }

        await withTaskGroup(of: (String, Result<Release, Error>).self) { group in
            for repo in repos {
                group.addTask {
                    do { return (repo, .success(try await ReleaseService.shared.latest(repo, force: force))) }
                    catch { return (repo, .failure(error)) }
                }
            }
            for await (repo, result) in group {
                switch result {
                case .success(let release):
                    releases[repo] = release
                    releaseErrors[repo] = nil
                case .failure(let error):
                    releaseErrors[repo] = error.localizedDescription
                    if case CatalogError.rateLimited = error { problem = error.localizedDescription }
                }
            }
        }

        // Forget games that were deleted from disk.
        let present = installed.filter { FileManager.default.fileExists(atPath: $0.value.path) }
        if present.count != installed.count {
            installed = present
            InstalledGames.save(present)
        }
        findPadMint()
        loading = false
    }

    // MARK: Queries

    /// Consoles in the catalog, most projects first.
    var consoles: [String] {
        let counts = Dictionary(grouping: catalog?.projects ?? [], by: \.console).mapValues(\.count)
        return counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
    }

    var visibleProjects: [CatalogProject] {
        (catalog?.projects ?? []).filter { project in
            guard project.matches(search), console == nil || project.console == console else { return false }
            switch filter {
            case .all: return true
            case .mac: return project.mac != nil
            case .ios: return project.ios != nil || project.usesPadMint
            case .android: return project.android != nil
            case .padmint: return project.usesPadMint
            }
        }
    }

    func release(_ project: CatalogProject) -> Release? { releases[project.repo] }
    func macAsset(_ project: CatalogProject) -> ReleaseAsset? { release(project)?.asset(for: project.mac) }
    func iosAsset(_ project: CatalogProject) -> ReleaseAsset? { release(project)?.asset(for: project.ios) }
    func androidAsset(_ project: CatalogProject) -> ReleaseAsset? { release(project)?.asset(for: project.android) }

    /// The card's version: the latest release's tag, plus any platform whose file
    /// comes from a different release, e.g. "2.9.5 · iOS 2.6.0".
    func versionText(_ project: CatalogProject) -> String? {
        guard let release = release(project) else { return nil }
        let others = [("Mac", macAsset(project)), ("iOS", iosAsset(project)), ("Android", androidAsset(project))]
            .compactMap { label, asset -> String? in
                guard let tag = asset?.tag, tag != release.tag else { return nil }
                return "\(label) \(ReleaseAsset.version(fromTag: tag))"
            }
        return ([release.tag] + others).joined(separator: " · ")
    }
    func installedGame(_ project: CatalogProject) -> InstalledGame? { installed[project.id] }

    func hasUpdate(_ project: CatalogProject) -> Bool {
        guard let installed = installed[project.id], let release = release(project) else { return false }
        return installed.tag != release.tag
    }

    func job(_ project: CatalogProject, _ platform: GamePlatform) -> GameJob? { jobs["\(project.id)-\(platform.rawValue)"] }

    // MARK: Mac games

    func installMac(_ project: CatalogProject) {
        guard let asset = macAsset(project), let release = release(project) else { return }
        let key = "\(project.id)-mac"
        guard jobs[key]?.running != true else { return }
        jobs[key] = GameJob(status: "Starting download…", fraction: 0)
        courier?.log("Downloading \(project.name) \(release.tag) for Mac (\(asset.name)).")

        Task {
            let work = GameInstaller.workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                let file = try await GameInstaller.download(asset, into: work) { fraction, text in
                    Task { @MainActor in self.update(key, fraction: fraction, status: "Downloading · \(text)") }
                }
                let result = try await GameInstaller.installMac(file, project: project) { status in
                    Task { @MainActor in self.update(key, fraction: nil, status: status) }
                }
                installed[project.id] = InstalledGame(tag: release.tag, path: result.url.path, installedAt: Date())
                InstalledGames.save(installed)

                var status = "Installed in ~/Applications/Games."
                if !result.notarized && result.url.pathExtension == "app" {
                    let allow = askToTrust(project, app: result.url)
                    for app in result.allApps { await GameInstaller.setQuarantine(!allow, at: app) }
                    status = allow
                        ? "Installed. You allowed it to open."
                        : "Installed. macOS will ask before it opens the first time."
                    courier?.log("\(project.name) isn't notarized; you chose \(allow ? "to allow it" : "to let macOS ask first").")
                }
                jobs[key] = GameJob(status: status, fraction: 1, running: false)
                courier?.log("Installed \(project.name) \(release.tag) at \(result.url.path).")
            } catch {
                jobs[key] = GameJob(status: "Couldn't install", error: error.localizedDescription, running: false)
                courier?.log("\(project.name): \(error.localizedDescription)")
            }
        }
    }

    /// Asks whether to open an un-notarized game without macOS's first-launch block.
    private func askToTrust(_ project: CatalogProject, app: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(app.deletingPathExtension().lastPathComponent)” isn't notarized by Apple"
        alert.informativeText = """
            It's a community build downloaded from github.com/\(project.repo). Apple hasn't checked it for malicious software.

            Allow it to open now? If you choose Let macOS Ask, macOS blocks it the first time you open it, and you can allow it later in System Settings → Privacy & Security.
            """
        alert.addButton(withTitle: "Let macOS Ask")
        alert.addButton(withTitle: "Allow")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func open(_ project: CatalogProject) {
        guard let path = installed[project.id]?.path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func reveal(_ project: CatalogProject) {
        guard let path = installed[project.id]?.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: iOS builds

    /// Downloads the iOS build into the IPA folder and adds it to the install queue.
    func addToQueue(_ project: CatalogProject) {
        guard let asset = iosAsset(project), let release = release(project) else { return }
        let key = "\(project.id)-ios"
        guard jobs[key]?.running != true else { return }
        jobs[key] = GameJob(status: "Starting download…", fraction: 0)
        let folder = courier?.libraryFolder ?? AppPaths.support.appendingPathComponent("Downloads", isDirectory: true)
        courier?.log("Downloading \(project.name) \(release.tag) for iPhone/iPad (\(asset.name)).")

        Task {
            let work = GameInstaller.workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                let ipa = try await GameInstaller.downloadIPA(asset, to: folder, work: work) { fraction, text in
                    Task { @MainActor in self.update(key, fraction: fraction, status: "Downloading · \(text)") }
                }
                await learnBundleID(of: ipa, for: project)
                courier?.add([ipa])
                courier?.tab = .discover
                jobs[key] = GameJob(status: "Added \(ipa.lastPathComponent) to the install queue.", fraction: 1,
                                    running: false, ipa: ipa)
                Task { await courier?.rescanLibrary() }
            } catch {
                jobs[key] = GameJob(status: "Couldn't download", error: error.localizedDescription, running: false)
                courier?.log("\(project.name): \(error.localizedDescription)")
            }
        }
    }

    /// Downloads the Android build (unpacking it from a zip if needed) and adds it to the Android queue.
    func addToAndroidQueue(_ project: CatalogProject) {
        guard let asset = androidAsset(project), let release = release(project), let android else { return }
        let key = "\(project.id)-android"
        guard jobs[key]?.running != true else { return }
        jobs[key] = GameJob(status: "Starting download…", fraction: 0)
        courier?.log("Downloading \(project.name) \(release.tag) for Android (\(asset.name)).")
        Task {
            let work = GameInstaller.workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                let file = try await GameInstaller.download(asset, into: work) { fraction, text in
                    Task { @MainActor in self.update(key, fraction: fraction, status: "Downloading · \(text)") }
                }
                var apk = file
                if APKKind(url: file) == nil {
                    let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
                    guard let found = try await GameInstaller.unpack(file, lookingFor: "apk", into: unpacked).first else {
                        throw GameInstallError.nothingFound("\(asset.name) doesn't contain an .apk file.")
                    }
                    apk = found
                }
                let destination = android.downloadsFolder.appendingPathComponent(apk.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: apk, to: destination)
                android.add([destination])
                courier?.tab = .discover
                jobs[key] = GameJob(status: "Added \(destination.lastPathComponent) to the Android queue.", fraction: 1,
                                    running: false, ipa: destination)
            } catch {
                jobs[key] = GameJob(status: "Couldn't download", error: error.localizedDescription, running: false)
                courier?.log("\(project.name): \(error.localizedDescription)")
            }
        }
    }

    func goToAndroid() {
        selected = nil
        courier?.tab = .android
    }

    func goToQueue() {
        selected = nil
        courier?.tab = .install
    }

    // MARK: PadMint

    var padMintRelease: Release? { catalog?.padmint.flatMap { releases[$0.repo] } }

    /// The version in the local PadMint folder name, e.g. "0.5.12" from "PadMint-v0.5.12".
    var padMintLocalVersion: String? {
        guard let folder = padMintCommand?.deletingLastPathComponent().lastPathComponent,
              let range = folder.range(of: #"\d+(\.\d+)+"#, options: .regularExpression) else { return nil }
        return String(folder[range])
    }

    var padMintIsOutdated: Bool {
        guard let local = padMintLocalVersion, let latest = padMintRelease?.tag else { return false }
        let remote = latest.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        return local.compare(remote, options: .numeric) == .orderedAscending
    }

    /// Finds the newest PadMint.command in the IPA folder or ~/Downloads.
    private func findPadMint() {
        var candidates: [URL] = []
        let roots = [courier?.libraryFolder, AppPaths.home.appendingPathComponent("Downloads")].compactMap { $0 }
        for root in roots {
            for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where folder.lastPathComponent.lowercased().hasPrefix("padmint") {
                let command = folder.appendingPathComponent("PadMint.command")
                if FileManager.default.fileExists(atPath: command.path) { candidates.append(command) }
            }
        }
        padMintCommand = candidates.max {
            $0.deletingLastPathComponent().lastPathComponent
                .compare($1.deletingLastPathComponent().lastPathComponent, options: .numeric) == .orderedAscending
        }
    }

    func openPadMint() {
        if let command = padMintCommand {
            NSWorkspace.shared.open(command)
            courier?.log("Opened PadMint. When it finishes a build, add the IPA it makes to the install queue.")
        } else if let repo = catalog?.padmint?.repo, let url = URL(string: "https://github.com/\(repo)/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Helpers

    private func update(_ key: String, fraction: Double?, status: String) {
        guard var job = jobs[key], job.running else { return }
        if let fraction { job.fraction = fraction }
        job.status = status
        jobs[key] = job
    }
}


// MARK: - Updates for apps on the device

/// A newer iOS release of a Discover project, for an app installed on the device.
struct DeviceAppUpdate: Equatable {
    let project: CatalogProject
    let asset: ReleaseAsset
    let version: String
}

/// Compares dotted versions numerically, treating missing parts as 0 ("1.0" == "1.0.0").
func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
    func parts(_ v: String) -> [Int] {
        v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l < r ? .orderedAscending : .orderedDescending }
    }
    return .orderedSame
}

extension DiscoverModel {
    /// Original bundle IDs → projects, from reliable sources only: the catalog's `bundleID`,
    /// and IPAs downloaded through Discover. (File-name rules aren't unique across projects:
    /// one project's "-ios-unsigned.ipa" rule also matches another's file.)
    private func links() -> [String: CatalogProject] {
        guard let catalog else { return [:] }
        let key = "\(catalog.revision ?? 0)|\(learnedBundleIDs.count)|\(catalog.projects.count)"
        if let cache = linkCache, cache.key == key { return cache.links }
        let byID = Dictionary(catalog.projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var links: [String: CatalogProject] = [:]
        for (bundleID, projectID) in learnedBundleIDs {
            if let project = byID[projectID], project.ios != nil { links[bundleID] = project }
        }
        for project in catalog.projects {
            if let id = project.ios?.bundleID { links[id] = project }
        }
        linkCache = (key, links)
        return links
    }

    /// Remembers which project an IPA downloaded through Discover belongs to.
    func learnBundleID(of ipa: URL, for project: CatalogProject) async {
        guard let info = try? await Signer.inspect(ipa), !info.bundleID.isEmpty else { return }
        learnedBundleIDs[info.bundleID] = project.id
        UserDefaults.standard.set(learnedBundleIDs, forKey: "discoverBundleIDs")
    }

    /// The newer release for an installed app, if its project has one with a comparable version.
    func update(for app: InstalledApp) -> DeviceAppUpdate? {
        guard let project = links().first(where: { Library.isSameApp(installed: app.bundleID, original: $0.key) })?.value,
              let release = release(project), let asset = iosAsset(project),
              let latest = ReleaseAsset.numericVersion(fromTag: asset.tag ?? release.tag)
        else { return nil }
        return compareVersions(latest, app.version) == .orderedDescending
            ? DeviceAppUpdate(project: project, asset: asset, version: latest) : nil
    }

    /// Updates for the connected device's sideloaded apps, keyed by installed bundle ID.
    var deviceUpdates: [String: DeviceAppUpdate] {
        guard let courier else { return [:] }
        var result: [String: DeviceAppUpdate] = [:]
        for status in courier.deviceApps {
            if let update = update(for: status.app) { result[status.app.bundleID] = update }
        }
        return result
    }

    func updateJob(_ update: DeviceAppUpdate) -> GameJob? { job(update.project, .ios) }

    /// Re-signs the app from the newer release: uses an IPA already in the folder when it's
    /// new enough, otherwise downloads it there first. Installs over the app, so data is kept.
    func installUpdates(_ pairs: [(DeviceAppStatus, DeviceAppUpdate)]) {
        guard let courier else { return }
        var ready: [(DeviceAppStatus, URL)] = []
        var downloads: [(DeviceAppStatus, DeviceAppUpdate)] = []
        for (status, update) in pairs {
            if let source = status.source, !source.version.isEmpty,
               compareVersions(source.version, update.version) != .orderedAscending {
                ready.append((status, source.url))
            } else if updateJob(update)?.running != true {
                downloads.append((status, update))
            }
        }
        if !ready.isEmpty { courier.resign(ready) }
        guard !downloads.isEmpty else { return }
        let folder = courier.libraryFolder ?? AppPaths.support.appendingPathComponent("Downloads", isDirectory: true)
        for (_, update) in downloads {
            jobs["\(update.project.id)-ios"] = GameJob(status: "Starting download…", fraction: 0)
        }
        Task {
            var downloaded: [(DeviceAppStatus, URL)] = []
            for (status, update) in downloads {
                let key = "\(update.project.id)-ios"
                let work = GameInstaller.workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                defer { try? FileManager.default.removeItem(at: work) }
                do {
                    let ipa = try await GameInstaller.downloadIPA(update.asset, to: folder, work: work) { fraction, text in
                        Task { @MainActor in self.update(key, fraction: fraction, status: "Downloading \(update.version) · \(text)") }
                    }
                    // Never install one app over another: the IPA must be this app.
                    let info = try await Signer.inspect(ipa)
                    guard Library.isSameApp(installed: status.app.bundleID, original: info.bundleID) else {
                        throw GameInstallError.nothingFound(
                            "\(ipa.lastPathComponent) is \(info.bundleID), not \(status.app.name) (\(status.app.bundleID)). Not installed.")
                    }
                    await learnBundleID(of: ipa, for: update.project)
                    jobs[key] = GameJob(status: "Downloaded \(ipa.lastPathComponent).", fraction: 1, running: false, ipa: ipa)
                    courier.log("Downloaded \(update.project.name) \(update.version) to update \(status.app.name).")
                    downloaded.append((status, ipa))
                } catch {
                    jobs[key] = GameJob(status: "Couldn't download", error: error.localizedDescription, running: false)
                    courier.log("\(update.project.name): \(error.localizedDescription)")
                }
            }
            await courier.rescanLibrary()
            if !downloaded.isEmpty { courier.resign(downloaded) }
        }
    }

    /// A notification for updates not mentioned before (once per app and version).
    func notifyIfNew(_ updates: [String: DeviceAppUpdate], device: String) {
        let key = "notifiedDeviceUpdates"
        var seen = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        let fresh = updates.filter { !seen.contains("\($0.key)@\($0.value.version)") }
        guard !fresh.isEmpty else { return }
        fresh.forEach { seen.insert("\($0.key)@\($0.value.version)") }
        UserDefaults.standard.set(Array(seen), forKey: key)

        let names = fresh.values.map { "\($0.project.name) \($0.version)" }.sorted()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let center = UNUserNotificationCenter.current()
            let content = UNMutableNotificationContent()
            content.title = names.count == 1 ? "Update for \(device)" : "\(names.count) updates for \(device)"
            content.body = names.joined(separator: ", ") + ". Open IPA Courier's On Device tab to install."
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
