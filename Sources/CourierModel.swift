import AppKit
import Combine
import Foundation

enum MainTab: Hashable {
    case install, onDevice
}

@MainActor
final class CourierModel: ObservableObject {
    // Device
    @Published var selectedUDID: String? {
        didSet { if oldValue != selectedUDID { Task { await loadDeviceState() } } }
    }
    @Published private(set) var installedApps: [InstalledApp] = []
    @Published private(set) var deviceProfiles: [DeviceProfile] = []
    @Published private(set) var loadingDeviceState = false

    // Signing
    @Published var selectedTeam: String? { didSet { if oldValue != selectedTeam { refreshAllPreviews() } } }
    @Published private(set) var teams: [DevTeam] = []
    private var profiles: [ProvisioningProfile] = []
    private var identities: [SigningIdentity] = []

    // Queue
    @Published private(set) var items: [QueueItem] = []
    @Published var selectedItemID: UUID?
    @Published private(set) var isRunning = false
    @Published private(set) var runningItemID: UUID?
    @Published var tab: MainTab = .install

    // Library
    @Published private(set) var libraryFolder: URL? = Library.folder
    @Published private(set) var libraryEntries: [LibraryEntry] = []
    @Published private(set) var indexingLibrary = false
    private var ledger = Library.loadLedger()

    @Published private(set) var logLines: [String] = []

    let devices = DeviceMonitor.shared
    private var task: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        cleanStaleJobs()
        devices.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                guard let self else { return }
                if let selected = self.selectedUDID, list.contains(where: { $0.udid == selected }) {
                    // Trust may have changed; reload what's installed once it's readable.
                    if let device = list.first(where: { $0.udid == selected }), device.trusted,
                       self.installedApps.isEmpty, !self.loadingDeviceState {
                        Task { await self.loadDeviceState() }
                    }
                } else {
                    self.selectedUDID = list.first?.udid
                }
            }
            .store(in: &cancellables)
        devices.start()
        Task {
            await reloadSigningAssets()
            await rescanLibrary()
        }
    }

    var selectedDevice: DeviceInfo? { devices.devices.first { $0.udid == selectedUDID } }
    var selectedItem: QueueItem? { items.first { $0.id == selectedItemID } }
    var readyCount: Int { items.filter { $0.status == .ready || $0.status == .inspecting }.count }

    var canStart: Bool {
        !isRunning && selectedDevice?.trusted == true && items.contains { $0.status == .ready }
    }

    /// Progress across the items in the current run.
    var queueProgress: Double {
        let active = items.filter { item in
            switch item.status {
            case .invalid: return false
            default: return true
            }
        }
        guard !active.isEmpty else { return 0 }
        return active.reduce(0) { $0 + $1.progress } / Double(active.count)
    }

    // MARK: Device state

    /// Reads installed apps and provisioning profiles, then re-matches the queue.
    func loadDeviceState() async {
        guard let udid = selectedUDID, selectedDevice?.trusted == true else {
            installedApps = []
            deviceProfiles = []
            rematchAll()
            return
        }
        loadingDeviceState = true
        async let apps = try? Installer.installedApps(udid: udid)
        let deviceProfiles = await devices.profiles(udid)
        let installed = await apps ?? []
        guard selectedUDID == udid else { return }
        self.installedApps = installed
        self.deviceProfiles = deviceProfiles
        loadingDeviceState = false
        rematchAll()
    }

    /// Sideloaded apps on the device with expiry and source IPA, soonest expiry first.
    var deviceApps: [DeviceAppStatus] {
        installedApps
            .filter(\.builtByDeveloper)
            .map { app in
                let profile = DeviceProfile.governing(app.bundleID, in: deviceProfiles)
                return DeviceAppStatus(
                    app: app,
                    expiration: profile?.expiration,
                    capabilities: profile?.capabilities ?? [],
                    source: Library.source(for: app.bundleID, entries: libraryEntries, ledger: ledger)
                )
            }
            .sorted { ($0.expiration ?? .distantFuture, $0.app.name) < ($1.expiration ?? .distantFuture, $1.app.name) }
    }

    var expiringSoonCount: Int { deviceApps.filter { $0.expires(within: 30) }.count }

    // MARK: Library

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder where you keep your IPAs."
        panel.directoryURL = libraryFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Library.folder = url
        libraryFolder = url
        Task { await rescanLibrary() }
    }

    func rescanLibrary() async {
        guard let folder = libraryFolder else { return }
        indexingLibrary = true
        libraryEntries = await Library.scan(folder) { [weak self] line in
            Task { @MainActor in self?.log(line) }
        }
        indexingLibrary = false
    }

    // MARK: Queue editing

    func add(_ urls: [URL]) {
        var ipas: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                ipas += inside.filter { $0.pathExtension.lowercased() == "ipa" }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if url.pathExtension.lowercased() == "ipa" {
                ipas.append(url)
            }
        }
        var added: [QueueItem] = []
        for url in ipas where !items.contains(where: { $0.url == url && !$0.status.isFinished }) {
            let item = QueueItem(url: url)
            items.append(item)
            added.append(item)
            inspect(item)
        }
        if libraryFolder == nil, let first = ipas.first {
            Library.folder = first.deletingLastPathComponent()
            libraryFolder = Library.folder
            Task { await rescanLibrary() }
        }
        if let first = added.first { selectedItemID = first.id }
        tab = .install
    }

    private func inspect(_ item: QueueItem) {
        // Re-publish item changes so queue-wide views (progress, counts) update.
        item.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        Task {
            do {
                let info = try await Signer.inspect(item.url)
                item.inspection = info
                item.status = .ready
                log("Added \(item.url.lastPathComponent): \(info.displayName) \(info.version), \(ByteFormat.string(info.uncompressedBytes)) unpacked.")
                match(item)
            } catch {
                item.status = .invalid(error.localizedDescription.components(separatedBy: "\n").first ?? "Not an IPA")
                item.errorDetail = error.localizedDescription
            }
        }
    }

    func remove(_ item: QueueItem) {
        guard item.status != .running else { return }
        removeSignedCopy(of: item)
        items.removeAll { $0.id == item.id }
        if selectedItemID == item.id { selectedItemID = items.first?.id }
    }

    func clearFinished() {
        for item in items where item.status.isFinished { removeSignedCopy(of: item) }
        items.removeAll { $0.status.isFinished }
        if selectedItem == nil { selectedItemID = items.first?.id }
    }

    /// Fills in the bundle ID and capabilities from what's on the device,
    /// unless the user has changed them.
    func match(_ item: QueueItem) {
        guard let ipa = item.inspection, item.isEditable else { return }
        item.existing = ExistingInstall.find(for: ipa.bundleID, in: installedApps,
                                             preferredTeams: [selectedTeam].compactMap { $0 } + teams.map(\.id))
        if let pinned = item.pinnedBundleID {
            item.bundleID = pinned
            item.autoBundleID = pinned
        } else if !item.userEditedBundleID {
            let target = item.existing?.app.bundleID ?? ipa.bundleID
            item.autoBundleID = target
            item.bundleID = target
        }
        if !item.userEditedCapabilities {
            let inherited = DeviceProfile.governing(item.trimmedBundleID, in: deviceProfiles)
                .flatMap { $0.isWildcard ? nil : $0.capabilities } ?? []
            item.autoCapabilities = inherited
            item.capabilities = inherited
        }
        refreshPreview(item)
    }

    private func rematchAll() {
        for item in items where item.inspection != nil { match(item) }
    }

    func useBundleID(_ id: String, for item: QueueItem) {
        item.autoBundleID = id
        item.bundleID = id
        refreshPreview(item)
    }

    // MARK: Signing assets and previews

    func reloadSigningAssets() async {
        profiles = Provisioning.loadProfiles()
        identities = await Provisioning.loadIdentities()
        teams = Provisioning.loadTeams(profiles: profiles)
        refreshAllPreviews()
    }

    private func refreshAllPreviews() {
        for item in items { refreshPreview(item) }
    }

    func refreshPreview(_ item: QueueItem) {
        guard let udid = selectedUDID, item.inspection != nil else {
            item.preview = ""
            item.previewReady = false
            return
        }
        let id = item.trimmedBundleID
        if let plan = Provisioning.plan(bundleID: id, udid: udid, team: selectedTeam, capabilities: item.capabilities,
                                        profiles: profiles, identities: identities) {
            item.preview = "Will sign with “\(plan.identity.name)” using “\(plan.profile.name)”, valid until \(plan.profile.expiration.formatted(date: .abbreviated, time: .omitted))."
            item.previewReady = true
        } else if teams.isEmpty {
            item.preview = "No developer team found. Sign in to Xcode → Settings → Accounts first."
            item.previewReady = false
        } else {
            let team = teams.first { $0.id == selectedTeam } ?? teams[0]
            if item.capabilities.isEmpty {
                item.preview = "No profile covers this device yet. Xcode will register the device and create one for \(team.label)."
            } else {
                item.preview = "Xcode will create a profile for \(id) with \(Capability.summary(item.capabilities)) (\(team.label))."
            }
            item.previewReady = true
        }
    }

    // MARK: Re-signing from the device list

    func resign(_ apps: [DeviceAppStatus]) {
        var first: QueueItem?
        for status in apps {
            guard let source = status.source else { continue }
            if items.contains(where: { $0.pinnedBundleID == status.app.bundleID && !$0.status.isFinished }) { continue }
            let item = QueueItem(url: source.url)
            item.pinnedBundleID = status.app.bundleID
            item.bundleID = status.app.bundleID
            item.autoBundleID = status.app.bundleID
            item.capabilities = status.capabilities
            item.autoCapabilities = status.capabilities
            items.append(item)
            inspect(item)
            first = first ?? item
        }
        guard let first else { return }
        selectedItemID = first.id
        tab = .install
        startQueue()
    }

    // MARK: Running

    func startQueue() {
        guard !isRunning, selectedDevice?.trusted == true else { return }
        task = Task { await processQueue() }
    }

    func cancel() { task?.cancel() }

    func retry(_ item: QueueItem, ignoreSpace: Bool = false) {
        guard item.status != .running, item.inspection != nil else { return }
        item.ignoreSpaceOnce = ignoreSpace
        item.status = .ready
        item.resetSteps()
        startQueue()
    }

    private func processQueue() async {
        isRunning = true
        defer {
            isRunning = false
            runningItemID = nil
        }
        while !Task.isCancelled {
            if let item = items.first(where: { $0.status == .ready }) {
                runningItemID = item.id
                selectedItemID = item.id
                await process(item)
            } else if items.contains(where: { $0.status == .inspecting }) {
                try? await Task.sleep(nanoseconds: 300_000_000)
            } else {
                break
            }
        }
        await loadDeviceState()
        if let udid = selectedUDID { await devices.refresh(udid) }
        let done = items.filter { $0.status == .done }.count
        let failed = items.filter { if case .failed = $0.status { return true }; return $0.status == .cancelled }.count
        log("Queue finished: \(done) installed" + (failed > 0 ? ", \(failed) failed or cancelled." : "."))
    }

    private func process(_ item: QueueItem) async {
        guard let ipa = item.inspection else { return }
        guard let udid = selectedUDID else {
            item.status = .failed("No device connected")
            return
        }
        item.status = .running
        item.resetSteps()
        let wantedID = item.trimmedBundleID
        let ignoreSpace = item.ignoreSpaceOnce
        item.ignoreSpaceOnce = false

        do {
            let app: SignedApp
            if let existing = item.signed, existing.bundleID == wantedID, existing.capabilities == item.capabilities,
               existing.profile.includes(udid: udid), FileManager.default.fileExists(atPath: existing.appURL.path) {
                app = existing
                for id in [StepID.provision, .unpack, .sign] { item.set(id, .skipped, "Already signed") }
            } else {
                // Keep at most one unpacked app on disk; they can be many GB each.
                for other in items where other.id != item.id { removeSignedCopy(of: other) }
                removeSignedCopy(of: item)
                app = try await signFresh(item, ipa: ipa, udid: udid, bundleID: wantedID)
                item.signed = app
            }

            item.set(.space, .running, "Reading free space…")
            guard let info = await devices.refresh(udid) else {
                throw StatusError(message: "The device was disconnected.")
            }
            guard let free = info.freeBytes else {
                throw StatusError(message: info.problem ?? "Couldn't read the device's free space. Unlock it and try again.")
            }
            let needed = app.size + 1_000_000_000
            if free < needed && !ignoreSpace {
                item.status = .needsSpace(SpaceShortfall(needed: needed, free: free))
                item.set(.space, .failed, "Needs about \(ByteFormat.string(needed)), \(ByteFormat.string(free)) free")
                item.errorDetail = "Not enough free space on \(info.name). Free up at least \(ByteFormat.string(needed - free)) (Settings → General → iPhone Storage), then click Re-check & Install. The signed app is kept, so it won't be signed again."
                log("\(item.name): not enough space on \(info.name).")
                return
            }
            item.set(.space, .done, "\(ByteFormat.string(free)) free · app needs \(ByteFormat.string(app.size))")

            let overWiFi = info.connection == .wifi
            item.set(.install, .running, overWiFi
                ? "Connecting over Wi-Fi… (slower than USB for large apps)"
                : "Connecting…")
            if overWiFi { log("Installing \(item.name) over Wi-Fi (\(ByteFormat.string(app.size))).") }
            try await Installer.install(app: app.appURL, udid: udid, connection: info.connection,
                                        progress: { [weak item] fraction, status in
                Task { @MainActor in item?.update(.install, fraction: fraction, detail: status) }
            }, log: { [weak self] line in
                Task { @MainActor in self?.log(line) }
            })
            item.set(.install, .done, "Installed on \(info.name)")
            item.status = .done
            Library.recordInstall(bundleID: wantedID, ipa: ipa.url)
            ledger = Library.loadLedger()
            log("\(ipa.displayName) is installed on \(info.name) as \(wantedID).")
        } catch is CancellationError {
            item.failRunningStep("Cancelled")
            item.status = .cancelled
            log("\(item.name): cancelled.")
        } catch {
            let message = error.localizedDescription
            item.failRunningStep(message.components(separatedBy: "\n").first ?? "Failed")
            item.status = .failed(message.components(separatedBy: "\n").first ?? "Failed")
            item.errorDetail = message
            log("\(item.name): \(message)")
        }
    }

    private func signFresh(_ item: QueueItem, ipa: IPAInspection, udid: String, bundleID: String) async throws -> SignedApp {
        let capabilities = item.capabilities
        item.set(.provision, .running, "Looking in your keychain and provisioning profiles…")
        let plan = try await resolvePlan(item, bundleID: bundleID, udid: udid, capabilities: capabilities)
        item.set(.provision, .done, "\(plan.identity.name) · \(plan.profile.name)")

        let job = AppPaths.jobs.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let macFree = (try? job.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        let macNeeded = ipa.uncompressedBytes + 2_000_000_000
        if macFree < macNeeded {
            try? FileManager.default.removeItem(at: job)
            throw StatusError(message: "This Mac needs about \(ByteFormat.string(macNeeded)) free to unpack the app; only \(ByteFormat.string(macFree)) is available.")
        }
        do {
            item.set(.unpack, .running, "Reading archive…")
            let total = ipa.uncompressedBytes
            let appURL = try await Signer.unpack(ipa, into: job) { [weak item] fraction, file in
                Task { @MainActor in
                    let done = ByteFormat.string(Int64(Double(total) * fraction))
                    item?.update(.unpack, fraction: fraction,
                                 detail: "\(done) of \(ByteFormat.string(total))" + (file.isEmpty ? "" : " · \(file)"))
                }
            }
            item.set(.unpack, .done, ByteFormat.string(total))

            item.set(.sign, .running, "Preparing…")
            try await Signer.sign(app: appURL, bundleID: bundleID, plan: plan, log: { [weak self] line in
                Task { @MainActor in self?.log(line) }
            }, status: { [weak item] status in
                Task { @MainActor in item?.update(.sign, fraction: nil, detail: status) }
            })
            let extras = plan.profile.capabilities.isEmpty ? "" : " with \(Capability.summary(plan.profile.capabilities))"
            item.set(.sign, .done, "Signed as \(bundleID)\(extras)")

            let size = await Signer.directorySize(appURL)
            return SignedApp(ipaURL: ipa.url, jobDirectory: job, appURL: appURL, bundleID: bundleID,
                             capabilities: capabilities, size: size, profile: plan.profile)
        } catch {
            try? FileManager.default.removeItem(at: job)
            throw error
        }
    }

    private func resolvePlan(_ item: QueueItem, bundleID: String, udid: String,
                             capabilities: Set<Capability>) async throws -> SigningPlan {
        await reloadSigningAssets()
        if let plan = Provisioning.plan(bundleID: bundleID, udid: udid, team: selectedTeam, capabilities: capabilities,
                                        profiles: profiles, identities: identities) {
            return plan
        }
        guard let team = selectedTeam ?? teams.first?.id else { throw ProvisioningError.noTeam }
        item.update(.provision, fraction: nil, detail: capabilities.isEmpty
            ? "Asking Xcode to register the device and create a profile…"
            : "Asking Xcode for a profile with \(Capability.summary(capabilities))…")
        try await Provisioning.refreshWithXcode(teamID: team, udid: udid, bundleID: bundleID,
                                                capabilities: capabilities) { [weak self] line in
            Task { @MainActor in self?.log(line) }
        }
        await reloadSigningAssets()
        if let plan = Provisioning.plan(bundleID: bundleID, udid: udid, team: team, capabilities: capabilities,
                                        profiles: profiles, identities: identities) {
            return plan
        }
        throw ProvisioningError.stillNoProfile(capabilities.isEmpty
            ? "The profile's certificate isn't in this Mac's keychain."
            : "Xcode's profile doesn't include \(Capability.summary(capabilities)). Check the App ID's capabilities at developer.apple.com.")
    }

    // MARK: Export and cleanup

    func exportSigned(_ item: QueueItem) {
        guard let signed = item.signed, !isRunning else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "ipa")!]
        panel.nameFieldStringValue = signed.ipaURL.deletingPathExtension().lastPathComponent + "-signed.ipa"
        panel.directoryURL = signed.ipaURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        isRunning = true
        log("Exporting signed IPA to \(destination.path)…")
        Task {
            do {
                try await Signer.exportIPA(jobDirectory: signed.jobDirectory, to: destination)
                log("Exported \(destination.lastPathComponent).")
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                item.errorDetail = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func removeSignedCopy(of item: QueueItem) {
        guard let signed = item.signed else { return }
        try? FileManager.default.removeItem(at: signed.jobDirectory)
        item.signed = nil
    }

    func cleanupAll() {
        for item in items { removeSignedCopy(of: item) }
    }

    func log(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        logLines.append("\(stamp)  \(line)")
        if logLines.count > 3000 { logLines.removeFirst(logLines.count - 3000) }
    }

    private func cleanStaleJobs() {
        for item in (try? FileManager.default.contentsOfDirectory(at: AppPaths.jobs, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: item)
        }
    }
}
