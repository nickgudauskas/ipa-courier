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

    /// Share of an item's progress bar.
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
    let capabilities: Set<Capability>
    let size: Int64
    let profile: ProvisioningProfile
}

struct SpaceShortfall: Equatable {
    let needed: Int64
    let free: Int64
}

enum ItemStatus: Equatable {
    case inspecting
    case ready
    case invalid(String)
    case running
    case done
    case failed(String)
    case cancelled
    case needsSpace(SpaceShortfall)

    var label: String {
        switch self {
        case .inspecting: return "Reading…"
        case .ready: return "Waiting"
        case .invalid(let why): return why
        case .running: return "Working…"
        case .done: return "Installed"
        case .failed(let why): return why
        case .cancelled: return "Cancelled"
        case .needsSpace(let s): return "Needs \(ByteFormat.string(s.needed - s.free)) more space on device"
        }
    }

    var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled, .needsSpace, .invalid: return true
        default: return false
        }
    }
}

struct StatusError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One IPA in the queue.
@MainActor
final class QueueItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL

    @Published var inspection: IPAInspection?
    @Published var bundleID = ""
    @Published var capabilities: Set<Capability> = []
    @Published var status: ItemStatus = .inspecting
    @Published var steps: [Step] = StepID.allCases.map { Step(id: $0) }
    @Published var existing: ExistingInstall?
    @Published var preview = ""
    @Published var previewReady = false
    @Published var errorDetail: String?
    @Published var signed: SignedApp?

    /// Values IPA Courier filled in itself; anything else means the user edited.
    var autoBundleID: String?
    var autoCapabilities: Set<Capability> = []
    /// Set by "Re-sign": always install over this exact bundle ID.
    var pinnedBundleID: String?
    var ignoreSpaceOnce = false

    init(url: URL) { self.url = url }

    var name: String { inspection?.displayName ?? url.deletingPathExtension().lastPathComponent }
    var trimmedBundleID: String { bundleID.trimmingCharacters(in: .whitespaces) }
    var isEditable: Bool { status != .running && status != .inspecting }

    var userEditedBundleID: Bool {
        guard let ipa = inspection else { return false }
        let current = trimmedBundleID
        return current != ipa.bundleID && current != autoBundleID
    }

    var userEditedCapabilities: Bool { capabilities != autoCapabilities }

    var progress: Double {
        switch status {
        case .done, .failed, .cancelled, .needsSpace, .invalid: return 1
        case .ready, .inspecting: return 0
        case .running:
            return steps.reduce(0) { total, step in
                switch step.state {
                case .done, .skipped: return total + step.id.weight
                case .running: return total + step.id.weight * (step.fraction ?? 0)
                default: return total
                }
            }
        }
    }

    func resetSteps() {
        steps = StepID.allCases.map { Step(id: $0) }
        errorDetail = nil
    }

    func set(_ id: StepID, _ state: StepState, _ detail: String) {
        steps[id.rawValue].state = state
        steps[id.rawValue].detail = detail
        steps[id.rawValue].fraction = state == .done ? 1 : nil
    }

    func update(_ id: StepID, fraction: Double?, detail: String) {
        guard steps[id.rawValue].state == .running else { return }
        if let fraction { steps[id.rawValue].fraction = fraction }
        if !detail.isEmpty { steps[id.rawValue].detail = detail }
    }

    func failRunningStep(_ detail: String) {
        if let index = steps.firstIndex(where: { $0.state == .running }) {
            steps[index].state = .failed
            steps[index].detail = detail
        }
    }
}

/// A sideloaded app on the device, with when it stops launching.
struct DeviceAppStatus: Identifiable, Equatable {
    let app: InstalledApp
    let expiration: Date?
    let capabilities: Set<Capability>
    let source: LibraryEntry?

    var id: String { app.bundleID }

    var daysLeft: Int? {
        expiration.map { Int(floor($0.timeIntervalSinceNow / 86_400)) }
    }

    func expires(within days: Int) -> Bool {
        guard let left = daysLeft else { return false }
        return left < days
    }
}
