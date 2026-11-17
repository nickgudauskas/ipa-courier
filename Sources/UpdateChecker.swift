import AppKit
import Foundation

struct AppUpdate: Equatable {
    let version: String
    let pageURL: URL
    let dmg: ReleaseAsset?
}

/// Checks IPA Courier's own GitHub releases for a newer version.
@MainActor
final class UpdateChecker: ObservableObject {
    static let repo = "nickgudauskas/ipa-courier"

    @Published private(set) var available: AppUpdate?
    @Published private(set) var job: GameJob?
    @Published private(set) var checking = false

    private let lastCheckKey = "lastUpdateCheck"
    private let skippedKey = "skippedUpdateVersion"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// "1.10" is newer than "1.9"; "1.4.1" is newer than "1.4".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    /// Checks at most once a day, quietly.
    func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 60 * 60 else { return }
        Task { await check(manual: false) }
    }

    /// `manual` (the menu item) also reports "up to date" and errors, and ignores a skipped version.
    func check(manual: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("IPA-Courier/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw CatalogError.http((response as? HTTPURLResponse)?.statusCode ?? 0, Self.repo)
            }
            struct Raw: Decodable {
                struct Asset: Decodable { let name: String; let size: Int64; let browser_download_url: URL }
                let tag_name: String
                let html_url: URL
                let assets: [Asset]
            }
            let raw = try JSONDecoder().decode(Raw.self, from: data)
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
            let version = raw.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let dmg = raw.assets.first { $0.name.lowercased().hasSuffix(".dmg") }
                .map { ReleaseAsset(name: $0.name, size: $0.size, downloadURL: $0.browser_download_url) }

            if Self.isNewer(version, than: currentVersion) {
                let skipped = UserDefaults.standard.string(forKey: skippedKey)
                if manual || version != skipped {
                    available = AppUpdate(version: version, pageURL: raw.html_url, dmg: dmg)
                }
            } else if manual {
                alert("You're up to date", "IPA Courier \(currentVersion) is the latest version.")
            }
        } catch {
            if manual { alert("Couldn't check for updates", error.localizedDescription) }
        }
    }

    func skip() {
        guard let update = available else { return }
        UserDefaults.standard.set(update.version, forKey: skippedKey)
        available = nil
        job = nil
    }

    func showReleaseNotes() {
        if let update = available { NSWorkspace.shared.open(update.pageURL) }
    }

    /// Downloads the new DMG into ~/Downloads and opens it, ready to drag into Applications.
    func download() {
        guard let update = available else { return }
        guard let dmg = update.dmg else {
            NSWorkspace.shared.open(update.pageURL)
            return
        }
        guard job?.running != true else { return }
        job = GameJob(status: "Starting download…", fraction: 0)
        Task {
            do {
                let downloads = AppPaths.home.appendingPathComponent("Downloads", isDirectory: true)
                let file = try await GameInstaller.download(dmg, into: downloads) { fraction, text in
                    Task { @MainActor in
                        self.job?.fraction = fraction
                        self.job?.status = "Downloading · \(text)"
                    }
                }
                NSWorkspace.shared.open(file)
                job = GameJob(status: "Opened \(file.lastPathComponent). Quit IPA Courier, drag the new copy to Applications to replace this one, then open it.",
                              fraction: 1, running: false)
            } catch {
                job = GameJob(status: "Couldn't download", error: error.localizedDescription, running: false)
            }
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
