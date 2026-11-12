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
                ipaSection
                signingSection
                progressSection
                logSection
            }
            .padding(20)
        }
        .frame(minWidth: 640, minHeight: 680)
        .fileImporter(isPresented: $importing, allowedContentTypes: [ipaType]) { result in
            if case .success(let url) = result { model.choose(url) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension.lowercased() == "ipa" else { return }
                Task { @MainActor in model.choose(url) }
            }
            return true
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
                        Text("Connect an iPhone or iPad with a USB cable").font(.headline)
                        Text("Unlock it and tap “Trust” if asked.").foregroundStyle(.secondary)
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
                            Task { await monitor.refresh(device.udid) }
                        }
                    }
                }
            }
        }
    }

    // MARK: IPA

    private var ipaSection: some View {
        Card(title: "App", systemImage: "shippingbox") {
            if let ipa = model.ipa {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ipa.displayName).font(.title3.weight(.semibold))
                        Text(ipa.url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 14) {
                            Fact("Version", ipa.version)
                            Fact("Unpacked", ByteFormat.string(ipa.uncompressedBytes))
                            if let os = ipa.minimumOS { Fact("Needs", "iOS \(os)+") }
                        }
                        .padding(.top, 2)
                    }
                    Spacer()
                    Button("Choose Another…") { importing = true }
                        .disabled(model.isRunning)
                }
            } else {
                Button { importing = true } label: {
                    VStack(spacing: 8) {
                        if model.inspecting {
                            ProgressView().controlSize(.small)
                            Text("Reading IPA…").foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "arrow.down.doc").font(.system(size: 26))
                            Text("Drop an .ipa here or click to choose").font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                            .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                    )
                }
                .buttonStyle(.plain)
                .disabled(model.inspecting)
            }
            if let error = model.inspectError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: Signing

    private var signingSection: some View {
        Card(title: "Signing", systemImage: "signature") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Team").foregroundStyle(.secondary)
                    Picker("Team", selection: $model.selectedTeam) {
                        Text("Automatic").tag(String?.none)
                        ForEach(model.teams) { team in
                            Text(team.label).tag(Optional(team.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }
                GridRow {
                    Text("Bundle ID").foregroundStyle(.secondary)
                    TextField("com.example.app", text: $model.bundleID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: 420)
                }
            }
            .disabled(model.isRunning)
            existingInstallNote
            if !model.preview.isEmpty {
                Label(model.preview, systemImage: model.previewReady ? "checkmark.seal" : "exclamationmark.triangle")
                    .foregroundStyle(model.previewReady ? Color.secondary : Color.orange)
                    .font(.callout)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var existingInstallNote: some View {
        if let ipa = model.ipa, let device = model.selectedDevice {
            let current = model.bundleID.trimmingCharacters(in: .whitespaces)
            VStack(alignment: .leading, spacing: 4) {
                if model.checkingExisting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Checking what's on \(device.name)…").foregroundStyle(.secondary)
                    }
                } else if let existing = model.existing {
                    if current == existing.app.bundleID {
                        Label {
                            Text("Updates the \(existing.app.name) \(existing.app.version) already on \(device.name)")
                            + Text(existing.teamSuffix != nil ? " (the copy installed with your team ID, e.g. by Sideloadly)" : "")
                            + Text(". Its saves and settings are kept.")
                        } icon: {
                            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.green)
                        }
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
                            Button("Update Existing Copy") { model.useBundleID(existing.app.bundleID) }
                        }
                    }
                } else if !model.checkingExisting {
                    Label("Not on \(device.name) yet; it will be installed as a new app.", systemImage: "plus.app")
                        .foregroundStyle(.secondary)
                }
                if current != ipa.bundleID && !(model.existing?.app.bundleID == current) {
                    Button("Use Original ID (\(ipa.bundleID))") { model.useBundleID(ipa.bundleID) }
                        .buttonStyle(.link)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .disabled(model.isRunning)
        }
    }

    // MARK: Progress

    private var progressSection: some View {
        Card(title: "Sign & Install", systemImage: "arrow.down.app") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.steps) { step in
                    StepRow(step: step)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: model.overallProgress)
                    Text("\(Int((model.overallProgress * 100).rounded()))% overall")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.top, 4)

                if let message = model.finishedMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                }
                if let error = model.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    if model.signed != nil && !model.isRunning {
                        Button("Export Signed IPA…") { model.exportSigned() }
                    }
                    Spacer()
                    if model.isRunning {
                        Button("Cancel", role: .cancel) { model.cancel() }
                    } else if model.shortfall != nil {
                        Button("Install Anyway") { model.retryInstall(ignoreSpace: true) }
                        Button("Re-check & Install") { model.retryInstall() }
                            .keyboardShortcut(.defaultAction)
                    } else if model.signed != nil && model.errorMessage != nil {
                        Button("Retry Install") { model.retryInstall() }
                        Button("Sign Again & Install") { model.start() }
                            .disabled(!model.canStart)
                    }
                    if !model.isRunning && model.shortfall == nil && !(model.signed != nil && model.errorMessage != nil) {
                        Button {
                            model.start()
                        } label: {
                            Text("Sign & Install").frame(minWidth: 110)
                        }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .disabled(!model.canStart)
                    }
                }
            }
        }
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

// MARK: - Pieces

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
                    Text(device.name).font(.title3.weight(.semibold))
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
