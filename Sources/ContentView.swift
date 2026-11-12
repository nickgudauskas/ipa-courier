import SwiftUI
import UniformTypeIdentifiers

private let ipaType = UTType(filenameExtension: "ipa") ?? .data

struct ContentView: View {
    @EnvironmentObject private var model: CourierModel
    @ObservedObject private var monitor = DeviceMonitor.shared
    @State private var importing = false
    @State private var dropTargeted = false
    @State private var showLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                deviceSection
                Picker("", selection: $model.tab) {
                    Text("Install").tag(MainTab.install)
                    Text(model.expiringSoonCount > 0 ? "On Device (\(model.expiringSoonCount) expiring)" : "On Device")
                        .tag(MainTab.onDevice)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch model.tab {
                case .install: installTab
                case .onDevice: OnDeviceView()
                }
                logSection
            }
            .padding(20)
        }
        .frame(minWidth: 700, minHeight: 720)
        .fileImporter(isPresented: $importing, allowedContentTypes: [ipaType, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.add([url]) }
                }
            }
            return !providers.isEmpty
        }
    }

    // MARK: Device

    private var deviceSection: some View {
        Card(title: "Device", systemImage: "iphone") {
            if let error = monitor.startupError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else if monitor.devices.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "cable.connector")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect an iPhone or iPad with a USB cable or over Wi-Fi").font(.headline)
                        Text("Unlock it and tap “Trust” if asked.").foregroundStyle(.secondary)
                        Text("For Wi-Fi, connect by USB once, then turn on “Show this iPhone when on Wi-Fi” in Finder and “Connect via network” in Xcode → Window → Devices and Simulators.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if monitor.devices.count > 1 {
                        Picker("Device", selection: $model.selectedUDID) {
                            ForEach(monitor.devices) { device in
                                Text(device.name).tag(Optional(device.udid))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320)
                        .disabled(model.isRunning)
                    }
                    if let device = model.selectedDevice {
                        DeviceRow(device: device) {
                            Task {
                                await monitor.refresh(device.udid)
                                await model.loadDeviceState()
                            }
                        }
                        if model.expiringSoonCount > 0 && model.tab == .install {
                            HStack {
                                Label("\(model.expiringSoonCount) app\(model.expiringSoonCount == 1 ? "" : "s") on \(device.name) stop opening within 30 days.",
                                      systemImage: "clock.badge.exclamationmark")
                                    .foregroundStyle(.orange)
                                Button("Review") { model.tab = .onDevice }
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }

    // MARK: Install tab

    @ViewBuilder private var installTab: some View {
        Card(title: "Queue", systemImage: "list.bullet.rectangle") {
            HStack {
                Text("Team").foregroundStyle(.secondary)
                Picker("Team", selection: $model.selectedTeam) {
                    Text("Automatic").tag(String?.none)
                    ForEach(model.teams) { team in Text(team.label).tag(Optional(team.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .disabled(model.isRunning)
                Spacer()
                Button("Add IPAs…") { importing = true }
                if model.items.contains(where: { $0.status.isFinished }) && !model.isRunning {
                    Button("Clear Finished") { model.clearFinished() }
                }
            }

            if model.items.isEmpty {
                Button { importing = true } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 26))
                        Text("Drop .ipa files or a folder here, or click to choose").font(.headline)
                        Text("They're signed and installed one after another.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                    )
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.items) { item in
                        QueueRow(item: item, selected: item.id == model.selectedItemID,
                                 canRemove: item.status != .running) {
                            model.remove(item)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectedItemID = item.id }
                        if item.id != model.items.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.25))
                )
            }

            if !model.items.isEmpty {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: model.queueProgress)
                        Text(queueSummary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if model.isRunning {
                        Button("Cancel", role: .cancel) { model.cancel() }
                    } else {
                        Button {
                            model.startQueue()
                        } label: {
                            Text(model.readyCount > 1 ? "Sign & Install \(model.readyCount)" : "Sign & Install")
                                .frame(minWidth: 120)
                        }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .disabled(!model.canStart)
                    }
                }
                .padding(.top, 4)
            }
        }

        if let item = model.selectedItem {
            ItemDetailView(item: item)
        }
    }

    private var queueSummary: String {
        let total = model.items.count
        let done = model.items.filter { $0.status == .done }.count
        let problems = model.items.filter {
            switch $0.status {
            case .failed, .cancelled, .needsSpace, .invalid: return true
            default: return false
            }
        }.count
        var parts = ["\(done) of \(total) installed"]
        if problems > 0 { parts.append("\(problems) need attention") }
        parts.append("\(Int((model.queueProgress * 100).rounded()))%")
        return parts.joined(separator: " · ")
    }

    // MARK: Log

    private var logSection: some View {
        DisclosureGroup("Log", isExpanded: $showLog) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
                            Text(line).id(index)
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 180)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .onChange(of: model.logLines.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Queue row

private struct QueueRow: View {
    @ObservedObject var item: QueueItem
    let selected: Bool
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            StatusIcon(status: item.status)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).fontWeight(.medium)
                    if let version = item.inspection?.version { Text(version).foregroundStyle(.secondary) }
                    ForEach(Capability.allCases.filter(item.capabilities.contains)) { cap in
                        Badge(cap.shortTitle)
                    }
                }
                if item.status == .running {
                    ProgressView(value: item.progress).controlSize(.small)
                }
                Text(rowDetail)
                    .font(.caption)
                    .foregroundStyle(isProblem ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if canRemove {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
                    .help("Remove from queue")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear)
    }

    private var isProblem: Bool {
        switch item.status {
        case .failed, .invalid, .needsSpace: return true
        default: return false
        }
    }

    private var rowDetail: String {
        switch item.status {
        case .running:
            let step = item.steps.first { $0.state == .running }
            return [step?.id.title, step?.detail].compactMap { $0 }.joined(separator: " · ")
        case .ready:
            return item.trimmedBundleID.isEmpty ? "Waiting" : "Waiting · \(item.trimmedBundleID)"
        default:
            return item.status.label
        }
    }
}

private struct StatusIcon: View {
    let status: ItemStatus

    var body: some View {
        Group {
            switch status {
            case .inspecting, .running: ProgressView().controlSize(.small)
            case .ready: Image(systemName: "circle").foregroundStyle(.secondary)
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .needsSpace: Image(systemName: "externaldrive.badge.exclamationmark").foregroundStyle(.orange)
            case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
            case .failed, .invalid: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - Item detail

private struct ItemDetailView: View {
    @EnvironmentObject private var model: CourierModel
    @ObservedObject var item: QueueItem

    var body: some View {
        Card(title: item.name, systemImage: "shippingbox") {
            if let ipa = item.inspection {
                HStack(spacing: 14) {
                    Fact("Version", ipa.version)
                    Fact("Unpacked", ByteFormat.string(ipa.uncompressedBytes))
                    if let os = ipa.minimumOS { Fact("Needs", "iOS \(os)+") }
                }
                Text(item.url.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Bundle ID").foregroundStyle(.secondary)
                        TextField("com.example.app", text: $item.bundleID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: 440)
                    }
                    GridRow(alignment: .top) {
                        Text("Capabilities").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Capability.allCases) { cap in
                                Toggle(isOn: Binding(
                                    get: { item.capabilities.contains(cap) },
                                    set: { on in
                                        if on { item.capabilities.insert(cap) } else { item.capabilities.remove(cap) }
                                    }
                                )) {
                                    Text(cap.title) + Text(" — \(cap.explanation)").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.callout)
                    }
                }
                .disabled(!item.isEditable)
                .padding(.top, 4)
                .onChange(of: item.bundleID) { _, _ in model.refreshPreview(item) }
                .onChange(of: item.capabilities) { _, _ in model.refreshPreview(item) }

                existingNote(ipa)

                if !item.preview.isEmpty {
                    Label(item.preview, systemImage: item.previewReady ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(item.previewReady ? Color.secondary : Color.orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().padding(.vertical, 2)
                ForEach(item.steps) { step in StepRow(step: step) }

                if let error = item.errorDetail {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            } else if case .invalid = item.status {
                Text(item.errorDetail ?? item.status.label).foregroundStyle(.red)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Reading IPA…").foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private func existingNote(_ ipa: IPAInspection) -> some View {
        if let device = model.selectedDevice {
            let current = item.trimmedBundleID
            VStack(alignment: .leading, spacing: 4) {
                if model.loadingDeviceState {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Checking what's on \(device.name)…").foregroundStyle(.secondary)
                    }
                } else if let existing = item.existing {
                    if current == existing.app.bundleID {
                        Label("Updates the \(existing.app.name) \(existing.app.version) already on \(device.name). Its saves and settings are kept.",
                              systemImage: "arrow.triangle.2.circlepath")
                        if let other = existing.otherCopy {
                            Text("Another copy (\(other.bundleID)) is also installed and won't be touched.")
                                .foregroundStyle(.secondary)
                                .padding(.leading, 22)
                        }
                    } else {
                        HStack {
                            Label("\(existing.app.name) is already on \(device.name) as \(existing.app.bundleID). This ID installs a separate copy.",
                                  systemImage: "plus.square.on.square")
                                .foregroundStyle(.orange)
                            Button("Update Existing Copy") { model.useBundleID(existing.app.bundleID, for: item) }
                        }
                    }
                } else {
                    Label("Not on \(device.name) yet; it will be installed as a new app.", systemImage: "plus.app")
                        .foregroundStyle(.secondary)
                }
                if current != ipa.bundleID && item.existing?.app.bundleID != current {
                    Button("Use Original ID (\(ipa.bundleID))") { model.useBundleID(ipa.bundleID, for: item) }
                        .buttonStyle(.link)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(!item.isEditable)
        }
    }

    @ViewBuilder private var actions: some View {
        HStack {
            if item.signed != nil && !model.isRunning {
                Button("Export Signed IPA…") { model.exportSigned(item) }
            }
            Spacer()
            if !model.isRunning {
                switch item.status {
                case .needsSpace:
                    Button("Install Anyway") { model.retry(item, ignoreSpace: true) }
                    Button("Re-check & Install") { model.retry(item) }
                case .failed, .cancelled:
                    Button("Retry") { model.retry(item) }
                case .done:
                    Button("Install Again") { model.retry(item) }
                default:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - On Device

private struct OnDeviceView: View {
    @EnvironmentObject private var model: CourierModel

    var body: some View {
        let apps = model.deviceApps
        let expiring = apps.filter { $0.expires(within: 30) && $0.source != nil }
        let resignable = apps.filter { $0.source != nil }

        Card(title: "Sideloaded Apps", systemImage: "clock.arrow.circlepath") {
            HStack {
                Text("IPA folder").foregroundStyle(.secondary)
                Text(model.libraryFolder?.path ?? "None chosen")
                    .lineLimit(1).truncationMode(.middle)
                if model.indexingLibrary { ProgressView().controlSize(.small) }
                Spacer()
                Button("Choose…") { model.chooseLibraryFolder() }
                Button {
                    Task {
                        await model.rescanLibrary()
                        await model.loadDeviceState()
                    }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .font(.callout)

            Text("Apps signed with a development certificate stop opening when their profile expires. Re-signing installs over the same app, so saves are kept, and keeps any memory capabilities the app has now.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.selectedDevice == nil {
                Text("Connect a device to see its apps.").foregroundStyle(.secondary)
            } else if model.loadingDeviceState && apps.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Reading apps and profiles…").foregroundStyle(.secondary) }
            } else if apps.isEmpty {
                Text("No sideloaded apps found on this device.").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(apps) { status in
                        DeviceAppRow(status: status, disabled: model.isRunning) { model.resign([status]) }
                        if status.id != apps.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))

                HStack {
                    let missing = apps.count - resignable.count
                    if missing > 0 {
                        Text("\(missing) app\(missing == 1 ? "" : "s") have no matching IPA in the folder.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Re-sign Expiring (\(expiring.count))") { model.resign(expiring) }
                        .disabled(expiring.isEmpty || model.isRunning || model.selectedDevice?.trusted != true)
                    Button("Re-sign All (\(resignable.count))") { model.resign(resignable) }
                        .disabled(resignable.isEmpty || model.isRunning || model.selectedDevice?.trusted != true)
                }
            }
        }
    }
}

private struct DeviceAppRow: View {
    let status: DeviceAppStatus
    let disabled: Bool
    let resign: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.app.name).fontWeight(.medium)
                    Text(status.app.version).foregroundStyle(.secondary)
                    ForEach(Capability.allCases.filter(status.capabilities.contains)) { cap in
                        Badge(cap.shortTitle)
                    }
                }
                Text(status.app.bundleID).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(status.source.map { "From \(URL(fileURLWithPath: $0.path).lastPathComponent)" } ?? "No matching IPA in the folder")
                    .font(.caption)
                    .foregroundStyle(status.source == nil ? .orange : .secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(expiryText).foregroundStyle(color).monospacedDigit()
                if let date = status.expiration {
                    Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Re-sign", action: resign)
                .disabled(status.source == nil || disabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var expiryText: String {
        guard let days = status.daysLeft else { return "Unknown" }
        if days < 0 { return "Expired" }
        if days == 0 { return "Expires today" }
        if days < 60 { return "\(days) day\(days == 1 ? "" : "s") left" }
        return "\(days / 30) months left"
    }

    private var color: Color {
        guard let days = status.daysLeft else { return .secondary }
        if days < 7 { return .red }
        if days < 30 { return .orange }
        return .secondary
    }

    private var icon: String {
        guard let days = status.daysLeft else { return "questionmark.circle" }
        if days < 0 { return "xmark.octagon.fill" }
        if days < 30 { return "clock.badge.exclamationmark" }
        return "checkmark.seal"
    }
}

// MARK: - Shared pieces

private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        } label: {
            Label(title, systemImage: systemImage).font(.headline)
        }
    }
}

private struct Badge: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
    }
}

private struct Fact: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
        .font(.callout)
    }
}

private struct DeviceRow: View {
    let device: DeviceInfo
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: device.deviceClass == "iPad" ? "ipad" : "iphone")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(device.name).font(.title3.weight(.semibold))
                        Label(device.connection.label, systemImage: device.connection.systemImage)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                            .help(device.connection == .usb
                                  ? "Connected by USB cable."
                                  : "Connected over Wi-Fi. Large apps install more slowly than over USB.")
                    }
                    if !device.summary.isEmpty {
                        Text(device.summary).foregroundStyle(.secondary).font(.callout)
                    }
                }
                Spacer()
                Button(action: refresh) { Label("Refresh", systemImage: "arrow.clockwise") }
            }

            if let free = device.freeBytes, let capacity = device.dataCapacity, capacity > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: Double(capacity - free), total: Double(capacity))
                        .tint(Double(free) / Double(capacity) < 0.1 ? .orange : .accentColor)
                    HStack {
                        Text("\(ByteFormat.string(free)) free of \(ByteFormat.string(capacity))")
                        if let purgeable = device.availableWithPurgeable, purgeable > free + 1_000_000_000 {
                            Text("· \(ByteFormat.string(purgeable)) counting purgeable").foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    .monospacedDigit()
                }
            }

            if device.developerMode == false {
                Label("Developer Mode is off. Turn it on in Settings → Privacy & Security → Developer Mode, or signed apps won't open.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            if let problem = device.problem {
                Label(problem, systemImage: "lock.iphone").foregroundStyle(.orange).font(.callout)
            }
        }
    }
}

private struct StepRow: View {
    let step: Step

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(step.id.title)
                    .foregroundStyle(step.state == .pending ? .secondary : .primary)
                if step.state == .running, let fraction = step.fraction {
                    HStack {
                        ProgressView(value: fraction)
                        Text("\(Int((fraction * 100).rounded()))%")
                            .monospacedDigit()
                            .font(.caption)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.caption)
                        .foregroundStyle(step.state == .failed ? .red : .secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch step.state {
        case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
