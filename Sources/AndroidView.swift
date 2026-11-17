import SwiftUI
import UniformTypeIdentifiers

private let apkTypes: [UTType] = ["apk", "xapk", "apks", "apkm"].compactMap { UTType(filenameExtension: $0) } + [.folder]

struct AndroidView: View {
    @EnvironmentObject private var android: AndroidModel
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            deviceCard
            queueCard
            foundCard
        }
        .onAppear { android.activate() }
        .fileImporter(isPresented: $importing, allowedContentTypes: apkTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { android.add(urls) }
        }
    }

    // MARK: Device

    private var deviceCard: some View {
        AndroidCard(title: "Android Device", systemImage: "candybarphone") {
            if android.adb == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("IPA Courier needs Google's Android Platform Tools (adb) to install apps over USB.")
                    Text("It uses an existing copy from Android Studio or Homebrew if you have one. Otherwise, download Google's official copy (about \(ByteFormat.string(AndroidTools.approximateDownloadSize))).")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    JobLine(job: android.toolsJob)
                    HStack {
                        Link("About Platform Tools", destination: AndroidTools.termsURL).font(.callout)
                        Spacer()
                        Button("Download Platform Tools") { android.downloadTools() }
                            .buttonStyle(.borderedProminent)
                            .disabled(android.toolsJob?.running == true)
                    }
                }
            } else if android.devices.isEmpty, let hidden = android.devicesWithoutDebugging.first {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 24)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("“\(hidden)” is connected, but USB debugging is off").font(.headline)
                        Text("Without USB debugging the device only offers file transfer, so apps can't be installed. On the device, open Settings → About phone (or About device) and tap Build number 7 times. Then turn on USB debugging in Settings → System → Developer options, unplug and replug the cable, and tap Allow.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            } else if android.devices.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "cable.connector").font(.system(size: 26)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect an Android phone or tablet with a USB cable").font(.headline)
                        Text("On the device, turn on Developer options (Settings → About phone → tap Build number 7 times), then turn on USB debugging in Settings → System → Developer options. Unlock it and allow this Mac when asked.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if android.devices.count > 1 {
                        Picker("Device", selection: $android.selectedSerial) {
                            ForEach(android.devices) { Text($0.name).tag(Optional($0.serial)) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320)
                        .disabled(android.isRunning)
                    }
                    if let device = android.selectedDevice {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "candybarphone")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.title3.weight(.semibold))
                                Text(device.summary).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                Task { await android.refreshSelected() }
                            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        }
                        if let free = device.freeBytes, let total = device.totalBytes, total > 0 {
                            ProgressView(value: Double(total - free), total: Double(total))
                                .tint(Double(free) / Double(total) < 0.1 ? .orange : .accentColor)
                            Text("\(ByteFormat.string(free)) free of \(ByteFormat.string(total))")
                                .font(.callout).monospacedDigit()
                        }
                        if let help = device.stateHelp {
                            Label(help, systemImage: "lock.iphone").foregroundStyle(.orange).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: Queue

    private var queueCard: some View {
        AndroidCard(title: "Install Queue", systemImage: "list.bullet.rectangle") {
            HStack {
                Text("APKs, split-APK bundles (.xapk, .apks) and folders")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Add APKs…") { importing = true }
                if android.items.contains(where: { $0.status.isFinished }) && !android.isRunning {
                    Button("Clear Finished") { android.clearFinished() }
                }
            }
            if android.items.isEmpty {
                Button { importing = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 24))
                        Text("Drop APK files here, or pick them from the list below").font(.headline)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(Color.secondary.opacity(0.5)))
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 0) {
                    ForEach(android.items) { item in
                        APKRow(item: item)
                        if item.id != android.items.last?.id { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))

                HStack {
                    Spacer()
                    if android.isRunning {
                        Button("Cancel", role: .cancel) { android.cancel() }
                    } else {
                        Button {
                            android.installAll()
                        } label: {
                            Text(android.readyCount > 1 ? "Install \(android.readyCount) on Android" : "Install on Android")
                                .frame(minWidth: 140)
                        }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .disabled(!android.canInstall)
                    }
                }
            }
        }
    }

    // MARK: Found on this Mac

    private var foundCard: some View {
        AndroidCard(title: "APKs on This Mac", systemImage: "magnifyingglass") {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by name or package", text: $android.search).textFieldStyle(.plain)
                if android.scanning { ProgressView().controlSize(.small) }
                Button { Task { await android.rescan() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Search the folders again")
                Button("Add Folder…") { android.addFolder() }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))

            Text("Searching " + android.scanFolders.map { $0.path.replacingOccurrences(of: AppPaths.home.path, with: "~") }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            if !android.extraFolders.isEmpty {
                HStack {
                    ForEach(android.extraFolders, id: \.self) { folder in
                        Button { android.removeFolder(folder) } label: {
                            Label(folder.lastPathComponent, systemImage: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Stop searching \(folder.path)")
                    }
                }
            }

            let apks = android.visibleFound
            if apks.isEmpty {
                Text(android.scanning ? "Searching…" : "No APKs found. Download one, add a folder, or get Android builds from the Discover tab.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                VStack(spacing: 0) {
                    ForEach(apks, id: \.url) { info in
                        FoundRow(info: info)
                        if info.url != apks.last?.url { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
            }
        }
    }
}

// MARK: - Rows

private struct APKRow: View {
    @EnvironmentObject private var android: AndroidModel
    @ObservedObject var item: APKItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                icon.frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name).fontWeight(.medium)
                        if let info = item.info {
                            Text(info.versionText).foregroundStyle(.secondary)
                            if info.kind.isBundle { Tag(info.kind.rawValue.uppercased()) }
                            if let state = android.installState(info) { Tag(state) }
                        }
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if item.status == .running, let fraction = item.fraction {
                        ProgressView(value: fraction).controlSize(.small)
                    } else if item.status == .running {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                }
                Spacer()
                actions
            }
            if let error = item.errorDetail {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var subtitle: String {
        if !item.detail.isEmpty && item.status != .ready { return item.detail }
        guard let info = item.info else {
            if case .invalid(let why) = item.status { return why }
            return "Reading…"
        }
        var parts = [info.package ?? info.url.lastPathComponent, ByteFormat.string(info.size)]
        if let min = info.minSdk { parts.append("needs \(AndroidDevice.androidVersion(forAPI: min))+") }
        if !info.abis.isEmpty { parts.append(info.abis.sorted().joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var icon: some View {
        switch item.status {
        case .reading, .running: ProgressView().controlSize(.small)
        case .ready: Image(systemName: "circle").foregroundStyle(.secondary)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .cancelled: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        case .signatureConflict, .downgrade: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .failed, .invalid: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var actions: some View {
        if !android.isRunning {
            switch item.status {
            case .done:
                Button("Open") { android.open(item) }
            case .failed, .cancelled:
                Button("Retry") { android.retry(item) }
            case .signatureConflict:
                Button("Uninstall & Install…") { android.uninstallAndInstall(item) }
            case .downgrade:
                Button("Install Older Version") { android.installOlder(item) }
            default:
                EmptyView()
            }
            if item.status != .running {
                Button { android.remove(item) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Remove from queue")
            }
        }
    }
}

private struct FoundRow: View {
    @EnvironmentObject private var android: AndroidModel
    let info: APKInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: info.kind.isBundle ? "shippingbox" : "app.badge").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(info.label).fontWeight(.medium)
                    Text(info.versionText).foregroundStyle(.secondary)
                    if let state = android.installState(info) { Tag(state) }
                }
                Text("\(info.package ?? "") · \(ByteFormat.string(info.size)) · \(info.url.deletingLastPathComponent().path.replacingOccurrences(of: AppPaths.home.path, with: "~"))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Add to Queue") { android.add([info.url]) }
                .disabled(android.items.contains { $0.url == info.url && !$0.status.isFinished })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Pieces

private struct AndroidCard<Content: View>: View {
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

private struct Tag: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

private struct JobLine: View {
    let job: GameJob?

    var body: some View {
        if let job {
            VStack(alignment: .leading, spacing: 4) {
                if job.running {
                    if let fraction = job.fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                }
                Label(job.error ?? job.status, systemImage: job.error != nil ? "xmark.octagon.fill" : job.running ? "arrow.down.circle" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(job.error != nil ? Color.red : job.running ? Color.secondary : Color.green)
            }
        }
    }
}
