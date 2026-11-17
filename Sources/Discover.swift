import AppKit
import Foundation

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
