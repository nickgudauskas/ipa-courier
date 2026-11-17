import SwiftUI

struct DiscoverView: View {
    @EnvironmentObject private var discover: DiscoverModel

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search games, consoles or projects", text: $discover.search)
                    .textFieldStyle(.plain)
                Picker("Console", selection: $discover.console) {
                    Text("All consoles").tag(String?.none)
                    Divider()
                    ForEach(discover.consoles, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .labelsHidden()
                .frame(width: 190)
                Picker("Show", selection: $discover.filter) {
                    ForEach(DiscoverFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 150)
                Button {
                    Task { await discover.load(force: true) }
                } label: {
                    if discover.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .help("Check for new releases")
                .disabled(discover.loading)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))

            Label(discover.catalog?.notice
                  ?? "IPA Courier doesn't provide game files. Each project needs your own copy of the original game.",
                  systemImage: "opticaldisc")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem = discover.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }

            if discover.catalog == nil && discover.loading {
                HStack { ProgressView().controlSize(.small); Text("Loading catalog…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if discover.visibleProjects.isEmpty {
                Text(discover.catalog == nil ? "The catalog isn't available." : "No projects match.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(discover.visibleProjects) { project in
                        ProjectCard(project: project)
                            .onTapGesture { discover.selected = project }
                    }
                }
            }

            if !discover.catalogSource.isEmpty {
                Text("\(discover.catalog?.projects.count ?? 0) projects · catalog from \(discover.catalogSource) · releases checked \(discover.indexDate.map { $0.formatted(.relative(presentation: .named)) } ?? "on GitHub")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .onAppear { discover.discoverShown() }
        .sheet(item: $discover.selected) { project in
            ProjectDetailView(project: project)
                .environmentObject(discover)
        }
    }
}

// MARK: - Card

private struct ProjectCard: View {
    @EnvironmentObject private var discover: DiscoverModel
    let project: CatalogProject
    @State private var hovering = false

    private func platformBadges(_ style: BadgeStyle) -> some View {
        HStack(spacing: 5) {
            if project.mac != nil { PlatformBadge("Mac", systemImage: "laptopcomputer", style: style) }
            if project.ios != nil { PlatformBadge("iPhone & iPad", short: "iOS", systemImage: "iphone", style: style) }
            if project.android != nil { PlatformBadge("Android", systemImage: "candybarphone", style: style) }
            if project.usesPadMint { PlatformBadge("PadMint", systemImage: "hammer", style: style) }
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProjectImage(project: project, height: 110)
            VStack(alignment: .leading, spacing: 5) {
                Text(project.name).font(.headline).lineLimit(1)
                Text("\(project.game) · \(project.console)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                // Full labels when they fit, then short ones, then short text alone, then icons only; never wrap mid-word.
                ViewThatFits(in: .horizontal) {
                    platformBadges(.full)
                    platformBadges(.short)
                    platformBadges(.textOnly)
                    platformBadges(.iconOnly)
                }
                HStack {
                    if let release = discover.release(project) {
                        Text(discover.versionText(project) ?? release.tag).monospacedDigit().lineLimit(1)
                        if let date = release.publishedAt {
                            Text(date.formatted(.relative(presentation: .named))).foregroundStyle(.tertiary)
                        }
                    } else if discover.releaseErrors[project.repo] != nil {
                        Text("Release unavailable").foregroundStyle(.orange)
                    } else {
                        Text("Checking…").foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if discover.hasUpdate(project) {
                        Text("Update").foregroundStyle(.orange).fontWeight(.semibold)
                    } else if discover.installedGame(project) != nil {
                        Label("Installed", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                    }
                }
                .font(.caption)
            }
            .padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(hovering ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: hovering ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The project's GitHub preview image, filling a fixed-height box at the column's width.
/// The box sets the size and the image is overlaid and clipped, so wide images can't
/// widen their card.
private struct ProjectImage: View {
    let project: CatalogProject
    let height: CGFloat
    @State private var image: NSImage?
    @State private var loading = true

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.1)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "gamecontroller").font(.system(size: 30)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .clipped()
            .task(id: project.id) {
                loading = true
                image = await RemoteImageCache.shared.image(for: project.imageURLs)
                loading = false
            }
            .accessibilityHidden(true)
    }
}

/// A platform's file in the detail sheet, with its own release when that differs from the latest.
private struct AssetLine: View {
    let asset: ReleaseAsset

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(asset.name) · \(ByteFormat.string(asset.size))")
            if let tag = asset.tag {
                HStack(spacing: 4) {
                    Text("From release")
                    if let page = asset.pageURL { Link(tag, destination: page) } else { Text(tag) }
                    if let date = asset.publishedAt {
                        Text("· \(date.formatted(date: .abbreviated, time: .omitted))")
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private enum BadgeStyle { case full, short, textOnly, iconOnly }

private struct PlatformBadge: View {
    let text: String
    let shortText: String
    let systemImage: String
    let style: BadgeStyle
    init(_ text: String, short: String? = nil, systemImage: String, style: BadgeStyle) {
        self.text = text; self.shortText = short ?? text; self.systemImage = systemImage; self.style = style
    }

    var body: some View {
        Group {
            switch style {
            case .full: Label(text, systemImage: systemImage)
            case .short: Label(shortText, systemImage: systemImage)
            case .textOnly: Text(shortText)
            case .iconOnly: Image(systemName: systemImage).accessibilityLabel(text)
            }
        }
            .lineLimit(1)
            .fixedSize()
            .help(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }
}

// MARK: - Detail

private struct ProjectDetailView: View {
    @EnvironmentObject private var discover: DiscoverModel
    @Environment(\.dismiss) private var dismiss
    let project: CatalogProject

    var body: some View {
        VStack(spacing: 0) {
            ProjectImage(project: project, height: 170)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name).font(.title2.weight(.bold))
                        Text("\(project.game) · \(project.console) · \(project.kind)").foregroundStyle(.secondary)
                    }
                    Text(project.summary).fixedSize(horizontal: false, vertical: true)

                    Label(project.requires, systemImage: "opticaldisc")
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                        .fixedSize(horizontal: false, vertical: true)

                    releaseLine

                    if project.mac != nil { macSection }
                    if project.ios != nil { iosSection }
                    if project.android != nil { androidSection }
                    if project.usesPadMint { padMintSection }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Link(destination: project.repoURL) { Label("Project on GitHub", systemImage: "arrow.up.right.square") }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 560, height: 640)
    }

    @ViewBuilder private var releaseLine: some View {
        if let release = discover.release(project) {
            HStack(spacing: 6) {
                Text("Latest release").foregroundStyle(.secondary)
                Link(release.tag, destination: release.pageURL)
                if let date = release.publishedAt {
                    Text("· \(date.formatted(date: .abbreviated, time: .omitted))").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        } else if let error = discover.releaseErrors[project.repo] {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
        }
    }

    // Mac

    private var macSection: some View {
        ActionSection(title: "Mac", systemImage: "laptopcomputer") {
            let asset = discover.macAsset(project)
            let installed = discover.installedGame(project)
            if let asset {
                AssetLine(asset: asset)
            } else if discover.release(project) != nil {
                Text("This release has no Mac build.").font(.callout).foregroundStyle(.secondary)
            }
            if let installed {
                Text("Installed \(installed.tag) at \(installed.path.replacingOccurrences(of: AppPaths.home.path, with: "~"))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            JobView(job: discover.job(project, .mac))
            HStack {
                if installed != nil {
                    Button("Open") { discover.open(project) }
                    Button("Show in Finder") { discover.reveal(project) }
                }
                Spacer()
                Button(installed == nil ? "Install on Mac" : discover.hasUpdate(project) ? "Update" : "Reinstall") {
                    discover.installMac(project)
                }
                .buttonStyle(.borderedProminent)
                .disabled(asset == nil || discover.job(project, .mac)?.running == true)
            }
        }
    }

    // iOS

    private var iosSection: some View {
        ActionSection(title: "iPhone & iPad", systemImage: "iphone") {
            let asset = discover.iosAsset(project)
            if let asset {
                AssetLine(asset: asset)
            }
            Text("Downloads the build to your IPA folder and adds it to the install queue, where it's signed with your developer account.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let job = discover.job(project, .ios)
            JobView(job: job)
            HStack {
                if job?.ipa != nil {
                    Button("Go to Install Queue") { discover.goToQueue() }
                }
                Spacer()
                Button("Download & Add to Queue") { discover.addToQueue(project) }
                    .buttonStyle(.borderedProminent)
                    .disabled(asset == nil || job?.running == true)
            }
        }
    }

    // Android

    private var androidSection: some View {
        ActionSection(title: "Android", systemImage: "candybarphone") {
            let asset = discover.androidAsset(project)
            if let asset {
                AssetLine(asset: asset)
            } else if discover.release(project) != nil {
                Text("This release has no Android build.").font(.callout).foregroundStyle(.secondary)
            }
            Text("Downloads the APK and adds it to the Android tab's queue, where it's installed over USB.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            let job = discover.job(project, .android)
            JobView(job: job)
            HStack {
                if job?.ipa != nil {
                    Button("Go to Android Queue") { discover.goToAndroid() }
                }
                Spacer()
                Button("Download & Add to Android Queue") { discover.addToAndroidQueue(project) }
                    .buttonStyle(.borderedProminent)
                    .disabled(asset == nil || job?.running == true)
            }
        }
    }

    // PadMint

    private var padMintSection: some View {
        ActionSection(title: "Build with PadMint", systemImage: "hammer") {
            Text("This project's releases only contain a game-free shell that isn't playable on its own. PadMint builds the playable app from your own game file. Then add the IPA it makes to the install queue.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let local = discover.padMintLocalVersion {
                HStack(spacing: 4) {
                    Text("PadMint \(local) found.")
                    if discover.padMintIsOutdated, let latest = discover.padMintRelease?.tag {
                        Text("\(latest) is available; download it to get this version's recipe.").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
            }
            HStack {
                Spacer()
                if discover.padMintCommand != nil {
                    if discover.padMintIsOutdated, let release = discover.padMintRelease {
                        Link("Get Latest PadMint", destination: release.pageURL)
                    }
                    Button("Open PadMint") { discover.openPadMint() }.buttonStyle(.borderedProminent)
                } else {
                    Button("Get PadMint") { discover.openPadMint() }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

private struct ActionSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        } label: {
            Label(title, systemImage: systemImage).font(.headline)
        }
    }
}

private struct JobView: View {
    let job: GameJob?

    var body: some View {
        if let job {
            VStack(alignment: .leading, spacing: 4) {
                if job.running {
                    if let fraction = job.fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Label(job.error ?? job.status,
                      systemImage: job.error != nil ? "xmark.octagon.fill"
                        : job.running ? "arrow.down.circle" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(job.error != nil ? Color.red : job.running ? Color.secondary : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}
