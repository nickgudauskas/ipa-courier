import AppKit
import Combine
import Foundation

enum StepID: Int, CaseIterable, Identifiable {
    case provision, unpack, sign, space, install
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .provision: return "Find certificate & profile"
        case .unpack: return "Unpack IPA"
        case .sign: return "Sign app"
        case .space: return "Check device storage"
        case .install: return "Copy & install on device"
        }
    }

    /// Share of the overall progress bar.
    var weight: Double {
        switch self {
        case .provision: return 0.03
        case .unpack: return 0.22
        case .sign: return 0.13
        case .space: return 0.02
        case .install: return 0.60
        }
    }
}

enum StepState: Equatable {
    case pending, running, done, failed, skipped
}

struct Step: Identifiable, Equatable {
    let id: StepID
    var state: StepState = .pending
    var detail = ""
    var fraction: Double?
}

struct SignedApp {
    let ipaURL: URL
    let jobDirectory: URL
    let appURL: URL
    let bundleID: String
    let size: Int64
    let profile: ProvisioningProfile
}

struct SpaceShortfall: Equatable {
    let needed: Int64
    let free: Int64
    let withPurgeable: Int64?
}

struct StatusError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class CourierModel: ObservableObject {
    // Inputs
    @Published var selectedUDID: String? {
        didSet {
            guard oldValue != selectedUDID else { return }
            refreshPreview()
            matchExistingInstall()
        }
    }
    /// The copy already on the device that this IPA will update, if any.
    @Published private(set) var existing: ExistingInstall?
    @Published private(set) var checkingExisting = false
    private var autoBundleID: String?
    private var matchToken = UUID()
    @Published private(set) var ipa: IPAInspection?
    @Published private(set) var inspecting = false
    @Published private(set) var inspectError: String?
    @Published var bundleID = "" { didSet { if oldValue != bundleID { refreshPreview() } } }
    @Published var selectedTeam: String? { didSet { if oldValue != selectedTeam { refreshPreview() } } }
    @Published private(set) var teams: [DevTeam] = []
    @Published private(set) var preview: String = ""
    @Published private(set) var previewReady = false

    // Run state
    @Published private(set) var steps: [Step] = StepID.allCases.map { Step(id: $0) }
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var shortfall: SpaceShortfall?
    @Published private(set) var finishedMessage: String?
    @Published private(set) var logLines: [String] = []
    @Published private(set) var signed: SignedApp?

    let devices = DeviceMonitor.shared
    private var task: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var profiles: [ProvisioningProfile] = []
    private var identities: [SigningIdentity] = []

    init() {
        cleanStaleJobs()
        devices.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                guard let self else { return }
                if let selected = self.selectedUDID, list.contains(where: { $0.udid == selected }) {
                    // Device details may have arrived; re-check signing.
                    self.refreshPreview()
                } else {
                    self.selectedUDID = list.first?.udid
                }
            }
            .store(in: &cancellables)
        devices.start()
        Task { await reloadSigningAssets() }
    }

    var selectedDevice: DeviceInfo? {
        devices.devices.first { $0.udid == selectedUDID }
    }

    var canStart: Bool {
        !isRunning && ipa != nil && selectedDevice?.trusted == true && !bundleID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var overallProgress: Double {
        steps.reduce(0) { total, step in
            switch step.state {
            case .done, .skipped: return total + step.id.weight
            case .running: return total + step.id.weight * (step.fraction ?? 0)
            default: return total
            }
        }
    }

    // MARK: Inputs

    func choose(_ url: URL) {
        guard !isRunning else { return }
        cleanupSigned()
        ipa = nil
        existing = nil
        autoBundleID = nil
        inspectError = nil
        finishedMessage = nil
        errorMessage = nil
        resetSteps()
        inspecting = true
        Task {
            do {
                let info = try await Signer.inspect(url)
                ipa = info
                bundleID = info.bundleID
                log("Selected \(url.lastPathComponent): \(info.displayName) \(info.version), \(ByteFormat.string(info.uncompressedBytes)) unpacked.")
            } catch {
                inspectError = error.localizedDescription
            }
            inspecting = false
            refreshPreview()
            matchExistingInstall()
        }
    }

    /// Looks for a copy of this app already on the device and, unless the
    /// user has typed their own bundle ID, targets it so the install updates
    /// that copy (keeping its data) instead of adding a second one.
    func matchExistingInstall() {
        guard let ipa, let udid = selectedUDID, !isRunning else {
            existing = nil
            checkingExisting = false
            return
        }
        let token = UUID()
        matchToken = token
        checkingExisting = true
        let preferredTeams = [selectedTeam].compactMap { $0 } + teams.map(\.id)
        Task {
            let apps = (try? await Installer.installedApps(udid: udid)) ?? []
            guard matchToken == token, self.ipa == ipa, selectedUDID == udid else { return }
            checkingExisting = false
            let match = ExistingInstall.find(for: ipa.bundleID, in: apps, preferredTeams: preferredTeams)
            existing = match

            let current = bundleID.trimmingCharacters(in: .whitespaces)
            let userEdited = current != ipa.bundleID && current != autoBundleID
            guard !userEdited else { return }
            let target = match?.app.bundleID ?? ipa.bundleID
            autoBundleID = target
            if bundleID != target {
                bundleID = target
                log("Found \(match?.app.name ?? ipa.displayName) on the device as \(target); installing will update it.")
            }
        }
    }

    func useBundleID(_ id: String) {
        autoBundleID = id
        bundleID = id
    }

    func reloadSigningAssets() async {
        profiles = Provisioning.loadProfiles()
        identities = await Provisioning.loadIdentities()
        teams = Provisioning.loadTeams(profiles: profiles)
        refreshPreview()
    }

    private func refreshPreview() {
        guard let udid = selectedUDID, ipa != nil else {
            preview = ""
            previewReady = false
            return
        }
        let id = bundleID.trimmingCharacters(in: .whitespaces)
        if let plan = Provisioning.plan(bundleID: id, udid: udid, team: selectedTeam,
                                        profiles: profiles, identities: identities) {
            preview = "Will sign with “\(plan.identity.name)” using “\(plan.profile.name)” (team \(plan.profile.teamID), valid until \(plan.profile.expiration.formatted(date: .abbreviated, time: .omitted)))."
            previewReady = true
        } else if teams.isEmpty {
            preview = "No developer team found. Sign in to Xcode → Settings → Accounts first."
            previewReady = false
        } else {
            let team = teams.first { $0.id == selectedTeam } ?? teams[0]
            preview = "No profile covers this device yet. Xcode will register the device and create one for \(team.label)."
            previewReady = true
        }
    }

    // MARK: Actions

    func start() {
        guard canStart else { return }
        task = Task { await run(reuseSigned: false, ignoreSpace: false) }
    }

    func retryInstall(ignoreSpace: Bool = false) {
        guard !isRunning, signed != nil else { return }
        task = Task { await run(reuseSigned: true, ignoreSpace: ignoreSpace) }
    }

    func cancel() {
        task?.cancel()
    }

    func exportSigned() {
        guard let signed, !isRunning else { return }
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
                errorMessage = error.localizedDescription
            }
            isRunning = false
        }
    }

    func cleanupSigned() {
        if let signed {
            try? FileManager.default.removeItem(at: signed.jobDirectory)
            log("Removed the unpacked copy of \(signed.ipaURL.lastPathComponent).")
        }
        signed = nil
    }

    // MARK: Pipeline

    private func run(reuseSigned: Bool, ignoreSpace: Bool) async {
        guard let udid = selectedUDID, let ipa else { return }
        isRunning = true
        errorMessage = nil
        shortfall = nil
        finishedMessage = nil
        resetSteps()

        do {
            var app: SignedApp
            let wantedID = bundleID.trimmingCharacters(in: .whitespaces)
            if reuseSigned, let existing = signed, existing.ipaURL == ipa.url,
               existing.bundleID == wantedID, existing.profile.includes(udid: udid) {
                app = existing
                for id in [StepID.provision, .unpack, .sign] { set(id, .skipped, "Already signed") }
            } else {
                cleanupSigned()
                app = try await signFresh(ipa: ipa, udid: udid, bundleID: wantedID)
                signed = app
            }

            // Storage check
            begin(.space, "Reading free space…")
            guard let info = await devices.refresh(udid) else {
                throw StatusError(message: "The device was disconnected.")
            }
            guard let free = info.freeBytes else {
                throw StatusError(message: info.problem ?? "Couldn't read the device's free space. Unlock it and try again.")
            }
            let needed = app.size + 1_000_000_000
            if free < needed && !ignoreSpace {
                shortfall = SpaceShortfall(needed: needed, free: free, withPurgeable: info.availableWithPurgeable)
                set(.space, .failed, "Needs about \(ByteFormat.string(needed)), \(ByteFormat.string(free)) free")
                errorMessage = "Not enough free space on \(info.name). Free up at least \(ByteFormat.string(needed - free)) (Settings → General → iPhone Storage), then click Re-check & Install. The signed app is kept, so it won't be signed again."
                isRunning = false
                return
            }
            set(.space, .done, "\(ByteFormat.string(free)) free · app needs \(ByteFormat.string(app.size))")

            // Install
            begin(.install, "Connecting…")
            let deviceName = info.name
            try await Installer.install(app: app.appURL, udid: udid, progress: { [weak self] fraction, status in
                Task { @MainActor in self?.update(.install, fraction: fraction, detail: status) }
            }, log: { [weak self] line in
                Task { @MainActor in self?.log(line) }
            })
            set(.install, .done, "Installed")
            finishedMessage = "\(ipa.displayName) is installed on \(deviceName)."
            log(finishedMessage!)
            await devices.refresh(udid)
            isRunning = false
            matchExistingInstall()
        } catch is CancellationError {
            failRunning("Cancelled")
            log("Cancelled.")
        } catch {
            failRunning(error.localizedDescription.components(separatedBy: "\n").first ?? "Failed")
            errorMessage = error.localizedDescription
            log("Error: \(error.localizedDescription)")
        }
        isRunning = false
    }

    private func signFresh(ipa: IPAInspection, udid: String, bundleID: String) async throws -> SignedApp {
        // 1. Certificate and profile
        begin(.provision, "Looking in your keychain and provisioning profiles…")
        let plan = try await resolvePlan(bundleID: bundleID, udid: udid)
        set(.provision, .done, "\(plan.identity.name) · \(plan.profile.name)")

        // 2. Unpack
        let job = AppPaths.jobs.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
        let macFree = (try? job.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        if macFree < ipa.uncompressedBytes + 2_000_000_000 {
            try? FileManager.default.removeItem(at: job)
            throw StatusError(message: "This Mac needs about \(ByteFormat.string(ipa.uncompressedBytes + 2_000_000_000)) free to unpack the app; only \(ByteFormat.string(macFree)) is available.")
        }
        do {
            begin(.unpack, "Reading archive…")
            let total = ipa.uncompressedBytes
            let appURL = try await Signer.unpack(ipa, into: job) { [weak self] fraction, file in
                Task { @MainActor in
                    let done = ByteFormat.string(Int64(Double(total) * fraction))
                    self?.update(.unpack, fraction: fraction,
                                 detail: "\(done) of \(ByteFormat.string(total))" + (file.isEmpty ? "" : " · \(file)"))
                }
            }
            set(.unpack, .done, ByteFormat.string(total))

            // 3. Sign
            begin(.sign, "Preparing…")
            try await Signer.sign(app: appURL, bundleID: bundleID, plan: plan, log: { [weak self] line in
                Task { @MainActor in self?.log(line) }
            }, status: { [weak self] status in
                Task { @MainActor in self?.update(.sign, fraction: nil, detail: status) }
            })
            set(.sign, .done, "Signed as \(bundleID)")

            let size = await Signer.directorySize(appURL)
            return SignedApp(ipaURL: ipa.url, jobDirectory: job, appURL: appURL,
                             bundleID: bundleID, size: size, profile: plan.profile)
        } catch {
            try? FileManager.default.removeItem(at: job)
            throw error
        }
    }

    private func resolvePlan(bundleID: String, udid: String) async throws -> SigningPlan {
        await reloadSigningAssets()
        if let plan = Provisioning.plan(bundleID: bundleID, udid: udid, team: selectedTeam,
                                        profiles: profiles, identities: identities) {
            return plan
        }
        guard let team = selectedTeam ?? teams.first?.id else { throw ProvisioningError.noTeam }
        update(.provision, fraction: nil, detail: "Asking Xcode to register the device and create a profile…")
        try await Provisioning.refreshWithXcode(teamID: team, udid: udid, bundleID: bundleID) { [weak self] line in
            Task { @MainActor in self?.log(line) }
        }
        await reloadSigningAssets()
        if let plan = Provisioning.plan(bundleID: bundleID, udid: udid, team: team,
                                        profiles: profiles, identities: identities) {
            return plan
        }
        throw ProvisioningError.stillNoProfile("The profile's certificate isn't in this Mac's keychain.")
    }

    // MARK: Step bookkeeping

    private func resetSteps() {
        steps = StepID.allCases.map { Step(id: $0) }
    }

    private func begin(_ id: StepID, _ detail: String) {
        set(id, .running, detail)
    }

    private func set(_ id: StepID, _ state: StepState, _ detail: String) {
        steps[id.rawValue].state = state
        steps[id.rawValue].detail = detail
        steps[id.rawValue].fraction = state == .done ? 1 : nil
    }

    private func update(_ id: StepID, fraction: Double?, detail: String) {
        guard steps[id.rawValue].state == .running else { return }
        if let fraction { steps[id.rawValue].fraction = fraction }
        if !detail.isEmpty { steps[id.rawValue].detail = detail }
    }

    private func failRunning(_ detail: String) {
        if let index = steps.firstIndex(where: { $0.state == .running }) {
            steps[index].state = .failed
            steps[index].detail = detail
        }
    }

    func log(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        logLines.append("\(stamp)  \(line)")
        if logLines.count > 3000 { logLines.removeFirst(logLines.count - 3000) }
    }

    private func cleanStaleJobs() {
        let jobs = AppPaths.jobs
        for item in (try? FileManager.default.contentsOfDirectory(at: jobs, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: item)
        }
    }
}
