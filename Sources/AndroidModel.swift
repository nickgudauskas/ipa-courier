import AppKit
import Combine
import Foundation

// MARK: - Device

struct AndroidDevice: Identifiable, Equatable {
    let serial: String
    var id: String { serial }
    /// adb's state: device, unauthorized, offline, "no permissions", …
    var state: String
    var model = ""
    var manufacturer = ""
    var release = ""
    var sdk: Int?
    var abis: [String] = []
    var freeBytes: Int64?
    var totalBytes: Int64?

    var ready: Bool { state == "device" }
    var overWiFi: Bool { serial.contains(":") || serial.contains("._adb-tls-") }

    var name: String {
        guard !model.isEmpty else { return serial }
        if manufacturer.isEmpty || model.lowercased().hasPrefix(manufacturer.lowercased()) { return model }
        return "\(manufacturer.capitalized) \(model)"
    }

    var summary: String {
        var parts: [String] = []
        if !release.isEmpty { parts.append("Android \(release)" + (sdk.map { " (API \($0))" } ?? "")) }
        if let abi = abis.first { parts.append(abi) }
        parts.append(overWiFi ? "Wi-Fi" : "USB")
        return parts.joined(separator: " · ")
    }

    var stateHelp: String? {
        switch state {
        case "device": return nil
        case "unauthorized":
            return "Unlock the device and tap Allow on the “Allow USB debugging?” prompt. Tick “Always allow from this computer” so it isn't asked again."
        case "offline": return "The device isn't responding. Unplug it, plug it back in and unlock it."
        case "authorizing", "connecting": return "Connecting…"
        default: return "adb reports “\(state)”. Unplug the device and plug it back in."
        }
    }

    static func androidVersion(forAPI api: Int) -> String {
        let names = [21: "5", 22: "5.1", 23: "6", 24: "7", 25: "7.1", 26: "8", 27: "8.1", 28: "9", 29: "10",
                     30: "11", 31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16", 37: "17"]
        return names[api].map { "Android \($0)" } ?? "API \(api)"
    }
}

// MARK: - Queue item

enum APKStatus: Equatable {
    case reading
    case ready
    case invalid(String)
    case running
    case done
    case failed(String)
    case cancelled
    /// Installed copy is signed by someone else; only uninstalling (and losing its data) allows it.
    case signatureConflict
    /// The device has a newer version.
    case downgrade

    var isFinished: Bool {
        switch self {
        case .reading, .ready, .running: return false
        default: return true
        }
    }
}

@MainActor
final class APKItem: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    @Published var info: APKInfo?
    @Published var status: APKStatus = .reading
    @Published var fraction: Double?
    @Published var detail = ""
    @Published var errorDetail: String?
    var allowDowngrade = false
    var uninstallFirst = false

    init(url: URL) { self.url = url }
    var name: String { info?.label ?? url.deletingPathExtension().lastPathComponent }
}

enum AndroidInstallError: LocalizedError {
    case failed(String)
    case signatureConflict
    case downgrade

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .signatureConflict:
            return "A copy of this app signed by a different developer is already installed. Android only allows replacing it after uninstalling, which deletes that app's data."
        case .downgrade:
            return "The device already has a newer version of this app."
        }
    }
}

// MARK: - Model

@MainActor
final class AndroidModel: ObservableObject {
    weak var courier: CourierModel?

    @Published private(set) var adb: URL? = AndroidTools.findADB()
    @Published private(set) var adbVersion: String?
    @Published private(set) var toolsJob: GameJob?
    @Published private(set) var devices: [AndroidDevice] = []
    /// Android devices macOS sees on USB that adb can't (USB debugging is off).
    @Published private(set) var devicesWithoutDebugging: [String] = []
    @Published var selectedSerial: String?
    @Published private(set) var items: [APKItem] = []
    @Published private(set) var isRunning = false
    /// package → versionCode of third-party apps on the selected device.
    @Published private(set) var installedVersions: [String: Int] = [:]
    @Published private(set) var found: [APKInfo] = []
    @Published private(set) var scanning = false
    @Published private(set) var extraFolders: [URL]
    @Published var search = ""

    private var pollTask: Task<Void, Never>?
    private var queueTask: Task<Void, Never>?
    private var infoCache: [String: (modified: Date, info: APKInfo)] = [:]
    private var cancellables = Set<AnyCancellable>()

    init() {
        extraFolders = (UserDefaults.standard.stringArray(forKey: "apkFolders") ?? []).map { URL(fileURLWithPath: $0) }
    }

    var selectedDevice: AndroidDevice? { devices.first { $0.serial == selectedSerial } }
    var readyCount: Int { items.filter { $0.status == .ready || $0.status == .reading }.count }
    var canInstall: Bool { !isRunning && selectedDevice?.ready == true && items.contains { $0.status == .ready } }

    var downloadsFolder: URL {
        let url = AppPaths.support.appendingPathComponent("Downloads/Android", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Folders searched for APKs: the IPA folder, Downloads, IPA Courier's Android downloads, and added folders.
    var scanFolders: [URL] {
        var folders = [courier?.libraryFolder, AppPaths.home.appendingPathComponent("Downloads"), downloadsFolder]
            .compactMap { $0 } + extraFolders
        var seen = Set<String>()
        folders = folders.filter { seen.insert($0.standardizedFileURL.path).inserted }
        return folders.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    var visibleFound: [APKInfo] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return found }
        return found.filter {
            [$0.label, $0.package ?? "", $0.url.lastPathComponent].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    // MARK: Lifecycle

    /// Called when the Android tab appears; adb's server only starts once someone uses Android features.
    func activate() {
        startPolling()
        if found.isEmpty && !scanning { Task { await rescan() } }
        if adbVersion == nil, let adb { Task { adbVersion = await AndroidTools.version(adb) } }
    }

    private func startPolling() {
        guard pollTask == nil, adb != nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollDevices()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func adbRun(_ arguments: [String], check: Bool = false) async throws -> Shell.Result {
        guard let adb else { throw AndroidToolsError.adbMissing }
        return try await Shell.run(adb.path, arguments, checkStatus: check)
    }

    // MARK: Devices

    func pollDevices() async {
        guard let result = try? await adbRun(["devices", "-l"]) else { return }
        var listed: [AndroidDevice] = []
        for line in result.text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 2, !line.hasPrefix("List of"), !line.hasPrefix("*") else { continue }
            let serial = parts[0]
            var state = parts[1]
            if state == "no", parts.count > 2, parts[2] == "permissions" { state = "no permissions" }
            var device = devices.first { $0.serial == serial } ?? AndroidDevice(serial: serial, state: state)
            let becameReady = state == "device" && (device.state != "device" || device.model.isEmpty)
            device.state = state
            if device.model.isEmpty, let model = parts.first(where: { $0.hasPrefix("model:") }) {
                device.model = String(model.dropFirst(6)).replacingOccurrences(of: "_", with: " ")
            }
            listed.append(device)
            if becameReady { Task { await loadDetails(serial) } }
        }
        if listed != devices { devices = listed }
        let hidden = listed.isEmpty ? await Self.androidDevicesOnUSB() : []
        if hidden != devicesWithoutDebugging { devicesWithoutDebugging = hidden }
        if selectedSerial == nil || !devices.contains(where: { $0.serial == selectedSerial }) {
            selectedSerial = devices.first(where: \.ready)?.serial ?? devices.first?.serial
        }
    }

    /// Names of USB devices from Android makers, read from macOS's USB registry. Used only
    /// when adb lists nothing, to tell "USB debugging is off" apart from "nothing plugged in".
    static func androidDevicesOnUSB() async -> [String] {
        guard let result = try? await Shell.run("/usr/sbin/ioreg", ["-p", "IOUSB", "-l", "-w0"]) else { return [] }
        // Vendors that make Android phones, tablets and handhelds (many OEMs use Google's ID).
        let androidVendors: Set<Int> = [0x18D1, 0x2717, 0x2A70, 0x22B8, 0x0BB4, 0x22D9, 0x2D95, 0x1004, 0x0FCE, 0x12D1, 0x05C6, 0x1EBF, 0x2AE5]
        var names: [String] = []
        var name: String?, vendorName: String?, vendor: Int?, product: Int?
        func flush() {
            defer { name = nil; vendorName = nil; vendor = nil; product = nil }
            guard let vendor else { return }
            let samsungPhone = vendor == 0x04E8 && [0x6860, 0x6861, 0x6866].contains(product ?? 0)
            guard androidVendors.contains(vendor) || samsungPhone else { return }
            var label = (name ?? "Android device").replacingOccurrences(of: #"\s*_SN:\S+"#, with: "", options: .regularExpression)
            if let vendorName, !vendorName.isEmpty, !label.localizedCaseInsensitiveContains(vendorName) { label += " (\(vendorName))" }
            names.append(label)
        }
        func quoted(_ line: Substring, _ key: String) -> String? {
            guard let range = line.range(of: "\"\(key)\" = \"") else { return nil }
            return String(line[range.upperBound...].dropLast())
        }
        func number(_ line: Substring, _ key: String) -> Int? {
            guard let range = line.range(of: "\"\(key)\" = ") else { return nil }
            return Int(line[range.upperBound...].trimmingCharacters(in: .whitespaces))
        }
        for line in result.text.split(whereSeparator: \.isNewline) {
            if line.contains("+-o ") { flush() }
            name = quoted(line, "USB Product Name") ?? name
            vendorName = quoted(line, "USB Vendor Name") ?? vendorName
            vendor = number(line, "idVendor") ?? vendor
            product = number(line, "idProduct") ?? product
        }
        flush()
        return names
    }

    /// Reads model, Android version, CPU types, free space and installed app versions.
    func loadDetails(_ serial: String) async {
        guard let props = try? await adbRun(["-s", serial, "shell", "getprop"]) else { return }
        var values: [String: String] = [:]
        for line in props.text.split(whereSeparator: \.isNewline) {
            // [ro.product.model]: [Pixel 8]
            let parts = line.components(separatedBy: "]: [")
            guard parts.count == 2 else { continue }
            values[String(parts[0].dropFirst())] = String(parts[1].dropLast())
        }
        let storage = await freeSpace(serial)
        guard let index = devices.firstIndex(where: { $0.serial == serial }) else { return }
        var device = devices[index]
        device.model = values["ro.product.model"] ?? device.model
        device.manufacturer = values["ro.product.manufacturer"] ?? ""
        device.release = values["ro.build.version.release"] ?? ""
        device.sdk = values["ro.build.version.sdk"].flatMap(Int.init)
        device.abis = (values["ro.product.cpu.abilist"] ?? values["ro.product.cpu.abi"] ?? "")
            .split(separator: ",").map(String.init)
        device.freeBytes = storage?.free
        device.totalBytes = storage?.total
        devices[index] = device
        if serial == selectedSerial { await loadInstalledVersions() }
    }

    private func freeSpace(_ serial: String) async -> (free: Int64, total: Int64)? {
        guard let df = try? await adbRun(["-s", serial, "shell", "df", "-k", "/data"]),
              let last = df.text.split(whereSeparator: \.isNewline).last else { return nil }
        let columns = last.split(whereSeparator: \.isWhitespace)
        guard columns.count >= 4, let total = Int64(columns[1]), let free = Int64(columns[3]) else { return nil }
        return (free * 1024, total * 1024)
    }

    func refreshSelected() async {
        guard let serial = selectedSerial else { return }
        await loadDetails(serial)
    }

    func loadInstalledVersions() async {
        guard let serial = selectedSerial,
              let result = try? await adbRun(["-s", serial, "shell", "pm", "list", "packages", "-3", "--show-versioncode"])
        else { return }
        var versions: [String: Int] = [:]
        for line in result.text.split(whereSeparator: \.isNewline) {
            // package:com.example versionCode:42
            let parts = line.split(separator: " ")
            guard let pkg = parts.first?.replacingOccurrences(of: "package:", with: ""),
                  let code = parts.first(where: { $0.hasPrefix("versionCode:") }).flatMap({ Int($0.dropFirst(12)) })
            else { continue }
            versions[pkg] = code
        }
        installedVersions = versions
    }

    /// "Installed", "Update" or nil, comparing an APK with what's on the selected device.
    func installState(_ info: APKInfo) -> String? {
        guard let package = info.package, let installed = installedVersions[package] else { return nil }
        guard let code = info.versionCode else { return "Installed" }
        if code > installed { return "Update" }
        if code < installed { return "Newer installed" }
        return "Installed"
    }

    // MARK: Platform Tools

    func downloadTools() {
        let alert = NSAlert()
        alert.messageText = "Download Android Platform Tools?"
        alert.informativeText = """
            IPA Courier uses Google's adb to talk to Android devices. This downloads Google's official Platform Tools (about \(ByteFormat.string(AndroidTools.approximateDownloadSize))) from dl.google.com into IPA Courier's folder.

            Platform Tools are covered by the Android Software Development Kit License Agreement (\(AndroidTools.termsURL.absoluteString)).
            """
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        toolsJob = GameJob(status: "Starting download…", fraction: 0)
        courier?.log("Downloading Android Platform Tools from Google.")
        Task {
            do {
                let adb = try await AndroidTools.downloadPlatformTools { [weak self] fraction, text in
                    Task { @MainActor in self?.toolsJob?.fraction = fraction; self?.toolsJob?.status = "Downloading · \(text)" }
                }
                self.adb = adb
                adbVersion = await AndroidTools.version(adb)
                toolsJob = GameJob(status: "Installed Platform Tools \(adbVersion ?? "")", fraction: 1, running: false)
                courier?.log("Installed Android Platform Tools \(adbVersion ?? "") at \(adb.path).")
                startPolling()
            } catch {
                toolsJob = GameJob(status: "Couldn't download", error: error.localizedDescription, running: false)
                courier?.log("Platform Tools: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Queue editing

    func add(_ urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                files += inside.filter { APKKind(url: $0) != nil }
            } else if APKKind(url: url) != nil {
                files.append(url)
            }
        }
        for url in files where !items.contains(where: { $0.url == url && !$0.status.isFinished }) {
            let item = APKItem(url: url)
            item.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
            items.append(item)
            Task {
                do {
                    item.info = try await APKReader.read(url)
                    item.status = .ready
                } catch {
                    item.status = .invalid(error.localizedDescription)
                }
            }
        }
        courier?.tab = .android
        activate()
    }

    func remove(_ item: APKItem) {
        guard item.status != .running else { return }
        items.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        items.removeAll { $0.status.isFinished }
    }

    // MARK: Installing

    func installAll() {
        guard canInstall else { return }
        queueTask = Task { await processQueue() }
    }

    func cancel() { queueTask?.cancel() }

    func retry(_ item: APKItem) {
        guard item.status != .running, item.info != nil else { return }
        item.status = .ready
        installAll()
    }

    func installOlder(_ item: APKItem) {
        item.allowDowngrade = true
        retry(item)
    }

    func uninstallAndInstall(_ item: APKItem) {
        guard let info = item.info, let device = selectedDevice else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall “\(info.label)” from \(device.name) first?"
        alert.informativeText = "The installed copy is signed by a different developer, so Android won't replace it. Uninstalling deletes that app and all of its data on the device, including saves, and can't be undone."
        alert.addButton(withTitle: "Uninstall & Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        item.uninstallFirst = true
        retry(item)
    }

    func open(_ item: APKItem) {
        guard let package = item.info?.package, let serial = selectedSerial else { return }
        Task {
            _ = try? await adbRun(["-s", serial, "shell", "monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1"])
        }
    }

    private func processQueue() async {
        isRunning = true
        defer { isRunning = false }
        while !Task.isCancelled {
            if let item = items.first(where: { $0.status == .ready }) {
                await install(item)
            } else if items.contains(where: { $0.status == .reading }) {
                try? await Task.sleep(nanoseconds: 300_000_000)
            } else {
                break
            }
        }
        await refreshSelected()
    }

    private func install(_ item: APKItem) async {
        guard let info = item.info else { return }
        guard let device = selectedDevice, device.ready else {
            item.status = .failed("No Android device ready")
            return
        }
        item.status = .running
        item.errorDetail = nil
        item.fraction = nil
        let downgrade = item.allowDowngrade
        let uninstall = item.uninstallFirst
        item.allowDowngrade = false
        item.uninstallFirst = false
        courier?.log("Installing \(info.label) \(info.versionText) on \(device.name).")

        do {
            // Compatibility
            if let need = info.minSdk, let have = device.sdk, need > have {
                throw AndroidInstallError.failed("\(info.label) needs \(AndroidDevice.androidVersion(forAPI: need)) or newer; \(device.name) runs \(AndroidDevice.androidVersion(forAPI: have)).")
            }
            if !info.abis.isEmpty, !device.abis.isEmpty, info.abis.isDisjoint(with: device.abis) {
                throw AndroidInstallError.failed("\(info.label) is built for \(info.abis.sorted().joined(separator: ", ")), but \(device.name) supports \(device.abis.joined(separator: ", ")).")
            }

            // Storage: a temporary copy on the device plus the installed app.
            item.detail = "Checking free space…"
            let storage = await freeSpace(device.serial)
            let needed = info.size * 2 + 300_000_000
            if let free = storage?.free, free < needed {
                throw AndroidInstallError.failed("Not enough free space on \(device.name): needs about \(ByteFormat.string(needed)), \(ByteFormat.string(free)) free.")
            }

            if uninstall, let package = info.package {
                item.detail = "Uninstalling the old copy…"
                _ = try? await adbRun(["-s", device.serial, "uninstall", package])
                courier?.log("Uninstalled \(package) from \(device.name).")
            }

            if info.kind == .apk {
                try await installSingle(item, apk: info.url, serial: device.serial, downgrade: downgrade)
            } else {
                try await installBundle(item, info: info, device: device, downgrade: downgrade)
            }
            item.status = .done
            item.fraction = 1
            item.detail = "Installed on \(device.name)"
            courier?.log("Installed \(info.label) on \(device.name).")
        } catch is CancellationError {
            item.status = .cancelled
            item.detail = "Cancelled"
        } catch AndroidInstallError.signatureConflict {
            item.status = .signatureConflict
            item.errorDetail = AndroidInstallError.signatureConflict.localizedDescription
            item.detail = "Signed differently from the installed copy"
        } catch AndroidInstallError.downgrade {
            item.status = .downgrade
            item.errorDetail = AndroidInstallError.downgrade.localizedDescription
            item.detail = "A newer version is installed"
        } catch {
            let message = error.localizedDescription
            item.status = .failed(message.components(separatedBy: "\n").first ?? "Failed")
            item.errorDetail = message
            item.detail = "Couldn't install"
            courier?.log("\(info.label): \(message)")
        }
    }

    /// Copies one APK to the device with progress, then installs it with the package manager.
    private func installSingle(_ item: APKItem, apk: URL, serial: String, downgrade: Bool) async throws {
        let remote = "/data/local/tmp/ipacourier-\(UUID().uuidString.prefix(8)).apk"
        try await push(item, file: apk, to: remote, serial: serial, label: "Copying to device")
        item.detail = "Installing…"
        item.fraction = nil
        var arguments = ["-s", serial, "shell", "pm", "install", "-r", "-t"]
        if downgrade { arguments.append("-d") }
        arguments.append(remote)
        let result = try await adbRun(arguments)
        _ = try? await adbRun(["-s", serial, "shell", "rm", "-f", remote])
        try Self.checkInstall(result.text)
    }

    /// Installs a split-APK bundle (.xapk / .apks) and copies any OBB data files.
    private func installBundle(_ item: APKItem, info: APKInfo, device: AndroidDevice, downgrade: Bool) async throws {
        let work = GameInstaller.workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        item.detail = "Unpacking \(info.url.lastPathComponent)…"
        try await GameInstaller.extract(info.url, into: work)

        var apks = GameInstaller.find("apk", in: work).filter { !$0.path.contains("/standalones/") }
        if let universal = apks.first(where: { $0.lastPathComponent.lowercased().contains("universal") }) { apks = [universal] }
        // Keep only the CPU split that matches the device best.
        let abiSplits = apks.filter { APKReader.splitABI($0.lastPathComponent) != nil }
        if !abiSplits.isEmpty {
            let best = device.abis.first { abi in abiSplits.contains { APKReader.splitABI($0.lastPathComponent) == abi } }
            apks.removeAll { split in
                guard let abi = APKReader.splitABI(split.lastPathComponent) else { return false }
                return abi != best
            }
        }
        guard !apks.isEmpty else { throw AndroidInstallError.failed("\(info.url.lastPathComponent) doesn't contain any APKs.") }

        if apks.count == 1 {
            try await installSingle(item, apk: apks[0], serial: device.serial, downgrade: downgrade)
        } else {
            item.detail = "Installing \(apks.count) split APKs…"
            item.fraction = nil
            var arguments = ["-s", device.serial, "install-multiple", "-r", "-t"]
            if downgrade { arguments.append("-d") }
            arguments += apks.map(\.path)
            try Self.checkInstall(try await adbRun(arguments).text)
        }

        // OBB expansion files, e.g. Android/obb/<package>/main.1.<package>.obb
        let obbs = GameInstaller.find("obb", in: work, maxDepth: 6)
        for (index, obb) in obbs.enumerated() {
            let relative = obb.path.replacingOccurrences(of: work.path + "/", with: "")
            let remote = relative.hasPrefix("Android/") ? "/sdcard/\(relative)"
                : "/sdcard/Android/obb/\(info.package ?? "unknown")/\(obb.lastPathComponent)"
            _ = try? await adbRun(["-s", device.serial, "shell", "mkdir", "-p", (remote as NSString).deletingLastPathComponent])
            try await push(item, file: obb, to: remote, serial: device.serial,
                           label: "Copying game data \(index + 1) of \(obbs.count)")
        }
    }

    /// adb push under a pseudo-terminal, so adb prints live percentages.
    func push(_ item: APKItem, file: URL, to remote: String, serial: String, label: String) async throws {
        guard let adb else { throw AndroidToolsError.adbMissing }
        item.detail = "\(label)…"
        item.fraction = 0
        let total = Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)

        // Current adb versions don't print copy progress, so measure it: poll the size
        // of the file growing on the device and compare it with the original's.
        let poller = Task { [weak self, weak item] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, total > 0, !Task.isCancelled,
                      let result = try? await self.adbRun(["-s", serial, "shell", "stat", "-c", "%s", remote]),
                      let copied = Int64(result.text.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                guard !Task.isCancelled else { break }
                item?.fraction = min(Double(copied) / Double(total), 0.99)
                item?.detail = "\(label) · \(ByteFormat.string(copied)) of \(ByteFormat.string(total))"
            }
        }
        defer { poller.cancel() }

        // Older adb versions print "[ 42%]" under a terminal; use that too when it appears.
        let parser = ProgressParser()
        let result = try await Shell.run("/usr/bin/script", ["-q", "/dev/null", adb.path, "-s", serial, "push", file.path, remote],
                                         checkStatus: false, onOutput: { [weak item] chunk in
            if let percent = parser.feed(chunk).percent {
                Task { @MainActor in
                    item?.fraction = percent / 100
                    item?.detail = "\(label) · \(Int(percent))%"
                }
            }
        })
        poller.cancel()
        item.fraction = 1
        let text = ProgressParser.clean(result.text)
        if result.status != 0 || text.contains("adb: error") || text.contains("error:") {
            let line = text.split(whereSeparator: \.isNewline).last { $0.contains("error") }.map(String.init) ?? text
            throw AndroidInstallError.failed("Copying to the device failed: \(line.trimmingCharacters(in: .whitespaces))")
        }
    }

    /// Turns package-manager output into success or a specific, actionable error.
    static func checkInstall(_ output: String) throws {
        if output.contains("Success") { return }
        let code = output.range(of: #"INSTALL_[A-Z_]+"#, options: .regularExpression).map { String(output[$0]) } ?? ""
        switch code {
        case "INSTALL_FAILED_UPDATE_INCOMPATIBLE": throw AndroidInstallError.signatureConflict
        case "INSTALL_FAILED_VERSION_DOWNGRADE": throw AndroidInstallError.downgrade
        case "INSTALL_FAILED_INSUFFICIENT_STORAGE":
            throw AndroidInstallError.failed("The device ran out of storage while installing. Free up space and try again.")
        case "INSTALL_FAILED_NO_MATCHING_ABIS":
            throw AndroidInstallError.failed("This APK has no native code for the device's CPU (for example, it's x86-only on an ARM phone).")
        case "INSTALL_FAILED_OLDER_SDK":
            throw AndroidInstallError.failed("This app needs a newer version of Android than the device has.")
        case "INSTALL_FAILED_USER_RESTRICTED":
            throw AndroidInstallError.failed("The device blocked installing over USB. In Developer options, turn on “Install via USB” (on Xiaomi devices, also “USB debugging (Security settings)”), then retry.")
        case "INSTALL_FAILED_TEST_ONLY":
            throw AndroidInstallError.failed("This is a test-only build that the device refuses to install.")
        case let parse where parse.hasPrefix("INSTALL_PARSE_FAILED"):
            throw AndroidInstallError.failed("The APK is damaged or not a valid Android package (\(parse)).")
        default:
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AndroidInstallError.failed(detail.isEmpty ? "The install failed without a message." : detail)
        }
    }

    // MARK: Finding APKs on this Mac

    func rescan() async {
        scanning = true
        defer { scanning = false }
        var urls: [URL] = []
        for folder in scanFolders {
            func walk(_ url: URL, depth: Int) {
                guard depth <= 2, urls.count < 400,
                      let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                                                               options: [.skipsHiddenFiles]) else { return }
                for item in items {
                    if APKKind(url: item) != nil {
                        urls.append(item)
                    } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                              item.pathExtension.isEmpty {
                        walk(item, depth: depth + 1)
                    }
                }
            }
            walk(folder, depth: 0)
        }

        var infos: [(Date, APKInfo)] = []
        for url in Set(urls) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if let cached = infoCache[url.path], cached.modified == modified {
                infos.append((modified, cached.info))
            } else if let info = try? await APKReader.read(url) {
                infoCache[url.path] = (modified, info)
                infos.append((modified, info))
            }
        }
        found = infos.sorted { $0.0 > $1.0 }.map(\.1)
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders to search for Android APKs."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !extraFolders.contains(url) { extraFolders.append(url) }
        UserDefaults.standard.set(extraFolders.map(\.path), forKey: "apkFolders")
        Task { await rescan() }
    }

    func removeFolder(_ url: URL) {
        extraFolders.removeAll { $0 == url }
        UserDefaults.standard.set(extraFolders.map(\.path), forKey: "apkFolders")
        Task { await rescan() }
    }
}
