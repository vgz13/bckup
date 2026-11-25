import AppKit
import SwiftUI

// MARK: - Main window

struct MainView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            DetailView()
        }
        .onAppear {
            app.openMainWindow = { openWindow(id: "main") }
            if ProcessInfo.processInfo.arguments.contains("--settings-cloud") { openSettings() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            app.addDropped(urls)
            return true
        } isTargeted: { app.dropTargeted = $0 }
        .overlay {
            if app.dropTargeted { DropOverlay().allowsHitTesting(false) }
        }
        .background(ShareSheetHost(share: app.share))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { app.selection = Nav.home } label: { Label("Home", systemImage: "house") }
                    .help("Back to Home (⌘1)")
            }
        }
    }
}

struct DropOverlay: View {
    var body: some View {
        Rectangle()
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .background(Color.accentColor.opacity(0.06))
            .overlay(alignment: .bottom) {
                Text("Drop here to copy a card, folder or files")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.white)
                    .padding(.bottom, 24)
            }
    }
}

// MARK: - Small building blocks

/// Plain secondary metadata text. (Was a pill; kept the name so call sites stay simple.)
struct Chip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol, tint != nil { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(tint ?? .secondary)
    }
}

/// A titled group, laid out like a macOS grouped form: small label above, quiet box below.
struct Panel<Content: View>: View {
    var title: String? = nil
    var symbol: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// A figure with its label, read like a line in a report rather than a dashboard tile.
struct StatTile: View {
    let value: String
    let label: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Used space (grey), space this offload will need (accent / red when it doesn't fit), free (track).
struct CapacityBar: View {
    let total: Int64
    let free: Int64
    var needed: Int64 = 0

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let t = Double(max(total, 1))
            let used = Double(max(0, total - free)) / t
            let need = min(Double(needed), Double(free)) / t
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                HStack(spacing: 0) {
                    Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: w * used)
                    Rectangle().fill(needed > free ? Color.red : Color.accentColor)
                        .frame(width: needed > 0 ? max(3, w * need) : 0)
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        List(selection: $app.selection) {
            Section("Library") {
                Label("Home", systemImage: "house").tag(Nav.home)
                Label("Projects", systemImage: "folder").tag(Nav.projects)
                Label("Sort downloads", systemImage: "arrow.down.circle").tag(Nav.downloads)
            }
            Section("Cards") {
                if app.cards.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "sdcard").foregroundStyle(.tertiary)
                        Text("Plug in a camera card…").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                ForEach(app.cards) { v in
                    SourceRow(url: v.url, name: v.name, subtitle: v.subtitle, symbol: "sdcard.fill", highlight: true).tag(v.url)
                }
            }
            if !app.otherVolumes.isEmpty {
                Section("Other drives") {
                    ForEach(app.otherVolumes) { v in
                        SourceRow(url: v.url, name: v.name, subtitle: v.subtitle, symbol: "externaldrive", highlight: false).tag(v.url)
                            .contextMenu { Button("Hide from list") { app.hide(v) } }
                    }
                }
            }
            if !app.manualSources.isEmpty {
                Section("Folder") {
                    ForEach(app.manualSources, id: \.self) { u in
                        SourceRow(url: u, name: app.sourceName(u), subtitle: app.sourceSubtitle(u),
                                  symbol: app.dropSets[u] == nil ? "folder.fill" : "doc.on.doc.fill", highlight: false).tag(u)
                            .contextMenu { Button("Remove from list") { app.removeManual(u) } }
                    }
                }
            }
            Section("Destinations") {
                if let p = app.settings.primaryRoot {
                    DestinationRow(path: p, role: "Main")
                } else {
                    Button("Choose main folder…") { app.choosePrimary() }.buttonStyle(.link)
                }
                ForEach(app.settings.backupRoots, id: \.self) { b in
                    DestinationRow(path: b, role: "Backup")
                }
                if app.settings.cloudEnabled {
                    HStack(spacing: 8) {
                        Image(systemName: "icloud.fill").foregroundStyle(.blue).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Google Drive")
                            Text(app.settings.cloudIssue ?? app.settings.cloudDisplay)
                                .font(.caption).foregroundStyle(app.settings.cloudIssue == nil ? Color.secondary : Color.orange).lineLimit(1)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                Button { app.chooseManualSource() } label: {
                    Label("Choose a source folder…", systemImage: "folder.badge.plus")
                }
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SourceRow: View {
    @EnvironmentObject var app: AppState
    let url: URL
    let name: String
    let subtitle: String
    let symbol: String
    let highlight: Bool

    var body: some View {
        if let job = app.existingJob(for: url) {
            SourceRowContent(job: job, name: name, subtitle: subtitle, symbol: symbol, highlight: highlight)
        } else {
            SourceRowLayout(name: name, subtitle: subtitle, symbol: symbol, highlight: highlight) { EmptyView() }
        }
    }
}

struct SourceRowContent: View {
    @ObservedObject var job: OffloadJob
    let name: String
    let subtitle: String
    let symbol: String
    let highlight: Bool

    var body: some View {
        SourceRowLayout(name: name, subtitle: job.stage == .idle ? subtitle : job.statusText, symbol: symbol, highlight: highlight) {
            switch job.stage {
            case .copying, .uploading:
                ProgressView(value: job.progress.fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            case .scanning, .planning:
                ProgressView().controlSize(.small)
            case .done:
                if let v = job.result?.verdict {
                    Image(systemName: v.symbol).foregroundStyle(v.color)
                }
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
    }
}

struct SourceRowLayout<Trailing: View>: View {
    let name: String
    let subtitle: String
    let symbol: String
    let highlight: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(highlight ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.vertical, 2)
    }
}

struct DestinationRow: View {
    let path: String
    let role: String

    var body: some View {
        let connected = FileManager.default.fileExists(atPath: path)
        let free = connected ? freeSpace(atPath: path) : nil
        let total = connected ? totalSpace(atPath: path) : nil
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: connected ? "externaldrive.fill" : "externaldrive.badge.xmark")
                .foregroundStyle(connected ? Color.green : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(volumeName(forPath: path)).lineLimit(1)
                    Text(role).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                if let free, let total, total > 0 {
                    CapacityBar(total: total, free: free)
                    Text("\(byteText(free)) free").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not connected").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .help(path)
    }
}

// MARK: - Detail

struct DetailView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if app.settings.primaryRoot == nil {
            SetupView()
        } else if app.selection == Nav.projects {
            ProjectsView(model: app.projectsModel)
        } else if app.selection == Nav.downloads {
            DownloadsView(model: app.downloadsModel)
        } else if let sel = app.selection, sel != Nav.home {
            JobView(job: app.job(for: sel)).id(sel)
        } else {
            HomeView()
        }
    }
}

struct SetupView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("BCKUP").font(.system(size: 34, weight: .bold))
            Text("Copy camera cards to several drives at once. Every file is checked by hash, files already there are skipped, and you know when a card is safe to format.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Start by choosing the folder where all your footage lives, for example your jobs folder on your working drive. Backup drives and Google Drive can be added later in Settings.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Choose main folder…") { app.choosePrimary() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(48)
        .frame(maxWidth: 580, alignment: .leading)
    }
}

// MARK: - Job screen

struct JobView: View {
    @ObservedObject var job: OffloadJob

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader(job: job)
                if job.scan == nil {
                    if case .error(let m) = job.stage {
                        Panel { ErrorLine(message: m) }
                    } else {
                        ProgressView("Reading the card…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                } else {
                    switch job.stage {
                    case .copying, .uploading:
                        ProgressPanel(job: job)
                        JobSummary(job: job)
                    case .done:
                        if let r = job.result { ResultPanel(job: job, result: r) }
                        JobSummary(job: job)
                    case .planned:
                        if let p = job.plan { PlanPanel(job: job, plan: p) }
                        SetupPanels(job: job)
                        CardPreview(job: job)
                    case .error(let m):
                        Panel { ErrorLine(message: m) }
                        SetupPanels(job: job)
                    default:
                        SetupPanels(job: job)
                        CardPreview(job: job)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if job.scan != nil { ActionBar(job: job) }
        }
        .navigationTitle(job.displayName)
        .navigationSubtitle(job.scan?.camera ?? "")
        .onAppear { job.scanIfNeeded() }
    }
}

struct ErrorLine: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct CardHeader: View {
    @ObservedObject var job: OffloadJob

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayName).font(.title.weight(.semibold)).lineLimit(1)
                Text(meta).font(.callout).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button { job.rescan() } label: { Image(systemName: "arrow.clockwise") }
                .help("Re-read the card")
                .disabled(job.isBusy)
            Button { job.openSideBySide() } label: { Text("Open side by side") }
                .help("Open the card and its destination folder in Finder, left and right")
            if job.isVolume {
                Button { job.eject() } label: { Label("Eject", systemImage: "eject") }
                    .disabled(job.isBusy)
            }
        }
    }

    private var meta: String {
        guard let s = job.scan else { return job.source.isFileURL ? job.source.path : "" }
        var parts = [s.model.map { "\($0) (\(s.camera))" } ?? s.camera, "\(s.files.count) files", byteText(s.totalBytes)]
        let kinds = [FileKind.video, .photo, .audio].compactMap { k -> String? in
            guard let n = s.counts[k], n > 0 else { return nil }
            return "\(n) \(k.label.lowercased())"
        }
        if !kinds.isEmpty { parts.append(kinds.joined(separator: ", ")) }
        if let a = s.firstDate, let b = s.lastDate {
            let f = dateFormatter("dd.MM.yy")
            let x = f.string(from: a), y = f.string(from: b)
            parts.append(x == y ? x : "\(x)–\(y)")
        }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Setup panels (project, destinations, options)

struct SetupPanels: View {
    @ObservedObject var job: OffloadJob

    var body: some View {
        VStack(spacing: 16) {
            ProjectPanel(job: job)
            DestinationPanel(job: job)
            OptionsPanel(job: job)
        }
        .disabled(job.isBusy)
    }
}

struct SuggestField: View {
    @Binding var text: String
    let placeholder: String
    let suggestions: [String]

    var body: some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
            Menu {
                if suggestions.isEmpty {
                    Text("No folders yet")
                } else {
                    Section("Existing folders") {
                        ForEach(suggestions, id: \.self) { s in
                            Button(s) { text = s }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Pick an existing folder")
        }
    }
}

struct ProjectPanel: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var job: OffloadJob
    @State private var showRename = false

    var body: some View {
        Panel(title: "Project", symbol: "folder") {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    if app.settings.useClientFolder {
                        FieldLabel("Client")
                        SuggestField(text: $job.client, placeholder: "Client name", suggestions: job.existingClients)
                    }
                    FieldLabel("Project")
                    SuggestField(text: $job.project, placeholder: "Project / shoot name", suggestions: job.existingProjects)
                        .gridCellColumns(app.settings.useClientFolder ? 1 : 3)
                }
                if job.asAssets {
                    GridRow {
                        FieldLabel("Date")
                        DatePicker("", selection: $job.date, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .fixedSize()
                            .disabled(job.projectExists || app.settings.datePosition == .none)
                            .gridCellColumns(app.settings.useClientFolder ? 3 : 3)
                            .gridCellAnchor(.leading)
                    }
                } else {
                    GridRow {
                        FieldLabel("Date")
                        DatePicker("", selection: $job.date, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.field)
                            .disabled(job.projectExists || app.settings.datePosition == .none)
                        FieldLabel("Roll")
                        TextField("Roll / card name", text: $job.roll)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            PathBreadcrumb(job: job)
            HStack {
                Spacer()
                Button("Rename folders…") { showRename = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .sheet(isPresented: $showRename) { RenameFoldersSheet().environmentObject(app) }
    }
}

struct FieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}

struct PathBreadcrumb: View {
    @ObservedObject var job: OffloadJob

    var body: some View {
        let parts = job.breadcrumb
        VStack(alignment: .leading, spacing: 4) {
            // One Text, so a long path wraps instead of pushing the window wider.
            parts.enumerated().reduce(Text("")) { acc, item in
                let (i, p) = item
                let sep = i > 0 ? Text("  ›  ").foregroundColor(.secondary.opacity(0.6)) : Text("")
                let part = Text(p.text)
                    .fontWeight(p.isNew ? .semibold : .regular)
                    .foregroundColor(p.isNew ? .accentColor : .secondary)
                return acc + sep + part
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            if job.projectExists {
                Text("This project already exists; new files go into the same folder.").font(.caption).foregroundStyle(.secondary)
            } else if parts.contains(where: \.isNew) {
                Text("Highlighted folders will be created.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .help(job.previewPath)
    }
}

struct DestinationPanel: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var job: OffloadJob

    var body: some View {
        Panel(title: "Save to", symbol: "externaldrive") {
            VStack(spacing: 10) {
                if let p = app.settings.primaryRoot {
                    DestinationOption(path: p, role: "Main", isOn: .constant(true), locked: true, needed: neededBytes(p))
                }
                ForEach(app.settings.backupRoots, id: \.self) { b in
                    DestinationOption(path: b, role: "Backup", isOn: job.backupBinding(b), locked: false, needed: neededBytes(b))
                }
                if app.settings.cloudEnabled {
                    HStack(spacing: 10) {
                        Toggle("", isOn: $job.useCloud).labelsHidden()
                        Image(systemName: "icloud.fill").foregroundStyle(.blue).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Google Drive")
                            Text(app.settings.cloudIssue ?? app.settings.cloudDisplay)
                                .font(.caption).foregroundStyle(app.settings.cloudIssue == nil ? Color.secondary : Color.orange)
                        }
                        Spacer()
                        Chip(text: "MD5 checked", symbol: "checkmark.shield")
                    }
                }
            }
            HStack(spacing: 16) {
                Button("Change main folder…") { app.choosePrimary() }
                Button("Add backup drive…") { app.addBackup() }
                Spacer()
                CopyCountHint(count: job.activeDestinations.count + (job.useCloud && app.settings.cloudEnabled ? 1 : 0))
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    private func neededBytes(_ root: String) -> Int64 {
        guard let plan = job.plan else { return 0 }
        return plan.summaries.first { $0.root == root }?.bytes ?? 0
    }
}

struct CopyCountHint: View {
    let count: Int
    var body: some View {
        if count >= 2 {
            Chip(text: "\(count) copies", symbol: "checkmark.circle.fill", tint: .green)
        } else {
            Chip(text: "1 copy, no backup yet", symbol: "exclamationmark.circle.fill", tint: .orange)
        }
    }
}

struct DestinationOption: View {
    let path: String
    let role: String
    @Binding var isOn: Bool
    let locked: Bool
    var needed: Int64 = 0

    var body: some View {
        let connected = FileManager.default.fileExists(atPath: path)
        let free = connected ? freeSpace(atPath: path) : nil
        let total = connected ? totalSpace(atPath: path) : nil
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: connected ? $isOn : .constant(false))
                .labelsHidden()
                .disabled(locked || !connected)
            Image(systemName: connected ? "externaldrive.fill" : "externaldrive.badge.xmark")
                .foregroundStyle(connected ? Color.green : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(volumeName(forPath: path)).fontWeight(.medium)
                    Text(role.lowercased())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !connected { Text("Not connected").font(.caption).foregroundStyle(.orange) }
                }
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if let free, let total, total > 0 {
                    CapacityBar(total: total, free: free, needed: needed)
                        .frame(maxWidth: 340)
                }
            }
            Spacer(minLength: 8)
            if let free {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(byteText(free)).font(.callout.monospacedDigit())
                    Text("free").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .opacity(connected ? 1 : 0.6)
    }
}

struct OptionsPanel: View {
    @ObservedObject var job: OffloadJob

    var body: some View {
        Panel(title: "Options", symbol: "slider.horizontal.3") {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Toggle("Skip files that are already there", isOn: $job.skipExisting)
                Spacer()
                Picker("Check", selection: $job.checkMode) {
                    Text("Thorough (hash)").tag(CheckMode.thorough)
                    Text("Quick").tag(CheckMode.fast)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(!job.skipExisting)
            }
            Text(job.skipExisting ? job.checkMode.help : "Every file on the card is copied. Files whose names already exist aren't overwritten; they get a _2 suffix.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("Save as assets in the \(job.settings.assetLayout.folder) folder", isOn: $job.asAssets)
            Text(job.asAssets
                 ? "For logos, music, briefs and client footage. Files are sorted into \(job.settings.splitMaterial ? "Video, Photo, Audio, Graphics, Documents and more" : "one folder")\(job.settings.groupByDevice && job.settings.splitMaterial ? ", with a folder per camera or phone" : "")."
                 : "For camera cards. Turn on for loose files that aren't from a card.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !job.asAssets {
                Toggle("Split into Video / Photo / Audio folders", isOn: $job.separateByType)
            }
        }
    }
}

/// Edit every folder name BCKUP creates, from the card screen.
struct RenameFoldersSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Folder names").font(.title2.weight(.semibold))
            Form {
                Section("Camera cards") {
                    TextField("Video", text: $app.settings.videoFolder)
                    TextField("Photo", text: $app.settings.photoFolder)
                    TextField("Audio", text: $app.settings.audioFolder)
                }
                Section("Assets") {
                    TextField("Assets folder", text: $app.settings.materialFolder)
                    Toggle("Split into a folder per type", isOn: $app.settings.splitMaterial)
                    Toggle("Folder per camera or phone (Video and Photo)", isOn: $app.settings.groupByDevice)
                        .disabled(!app.settings.splitMaterial)
                    ForEach(AssetCategory.allCases) { c in
                        TextField(c.defaultName, text: Binding(
                            get: { app.settings.materialNames[c.rawValue] ?? c.defaultName },
                            set: { app.settings.materialNames[c.rawValue] = $0 }
                        ))
                        .help(c.examples)
                        .disabled(!app.settings.splitMaterial)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Reset to defaults") {
                    let d = AppSettings()
                    app.settings.videoFolder = d.videoFolder
                    app.settings.photoFolder = d.photoFolder
                    app.settings.audioFolder = d.audioFolder
                    app.settings.materialFolder = d.materialFolder
                    app.settings.splitMaterial = d.splitMaterial
                    app.settings.groupByDevice = d.groupByDevice
                    app.settings.materialNames = [:]
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("New names apply to folders made from now on. Folders already on your drives aren't renamed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460, height: 640)
    }
}

// MARK: - Bottom action bar

struct ActionBar: View {
    @ObservedObject var job: OffloadJob

    var body: some View {
        HStack(spacing: 14) {
            leading
            Spacer(minLength: 10)
            trailing
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder private var leading: some View {
        switch job.stage {
        case .ready, .idle, .scanning:
            if let issue = job.validationIssue {
                Label(issue, systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
            } else {
                Label(job.skipExisting ? "Ready. BCKUP checks what's already there first." : "Ready. Every file will be copied.",
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        case .planning:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(job.progress.phase).foregroundStyle(.secondary).lineLimit(1)
                if job.progress.total > 0 { Text("\(Int(job.progress.fraction * 100))%").monospacedDigit().foregroundStyle(.secondary) }
            }
        case .planned:
            if let p = job.plan {
                HStack(spacing: 6) {
                    Text(p.filesToCopy == 0 ? "Nothing to copy" : "\(p.filesToCopy) files to copy").fontWeight(.semibold)
                    Text("· \(byteText(p.bytesToCopy)) · \(p.items.count - p.filesToCopy) already complete").foregroundStyle(.secondary)
                }
            }
        case .copying, .uploading:
            HStack(spacing: 10) {
                ProgressView(value: job.progress.fraction).frame(width: 200)
                Text("\(Int(job.progress.fraction * 100))%").monospacedDigit().fontWeight(.semibold)
                if job.speed > 1 { Text("\(byteText(Int64(job.speed)))/s").monospacedDigit().foregroundStyle(.secondary) }
            }
        case .done:
            if let v = job.result?.verdict {
                Label(v.title, systemImage: v.symbol).foregroundStyle(v.color).fontWeight(.semibold)
            }
        case .error(let m):
            Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(1)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch job.stage {
        case .ready, .idle, .scanning:
            Button { job.check() } label: {
                Label(job.isVolume ? "Check card" : "Check files", systemImage: "magnifyingglass").padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(job.validationIssue != nil || job.stage != .ready)
        case .planning, .copying, .uploading:
            Button("Cancel", role: .cancel) { job.cancelWork() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        case .planned:
            Button("Check again") { job.check() }
                .controlSize(.large)
            if let p = job.plan {
                Button { job.start() } label: {
                    Label(p.filesToCopy == 0 ? "Selesaikan" : "Start copy", systemImage: "arrow.down.circle.fill").padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(p.hasSpaceProblem)
            }
        case .done:
            Button("Check again") { job.resetToReady() }
                .controlSize(.large)
            if job.isVolume, job.result?.verdict.isGood == true {
                Button { job.eject() } label: {
                    Label("Eject card", systemImage: "eject.fill").padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.green)
            } else {
                Button { job.revealProject() } label: {
                    Label("Show in Finder", systemImage: "folder").padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        case .error:
            Button("Try again") { job.resetToReady() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

// MARK: - Plan

struct PlanPanel: View {
    @ObservedObject var job: OffloadJob
    let plan: OffloadPlan

    var body: some View {
        Panel(title: "Check result", symbol: "checklist") {
            HStack(spacing: 10) {
                StatTile(value: "\(plan.filesToCopy)", label: "files to copy", tint: plan.filesToCopy > 0 ? .accentColor : .primary)
                StatTile(value: byteText(plan.bytesToCopy), label: "to read from the card")
                StatTile(value: "\(plan.items.count - plan.filesToCopy)", label: "already on every destination", tint: .green)
                if plan.renamedCount > 0 {
                    StatTile(value: "\(plan.renamedCount)", label: "name clashes", tint: .orange)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(plan.summaries, id: \.root) { s in
                    HStack(spacing: 10) {
                        Image(systemName: s.spaceProblem ? "exclamationmark.triangle.fill" : "externaldrive.fill")
                            .foregroundStyle(s.spaceProblem ? Color.red : .secondary)
                            .frame(width: 22)
                        Text(volumeName(forPath: s.root)).fontWeight(.medium).frame(minWidth: 110, alignment: .leading)
                        if let total = totalSpace(atPath: s.root), let free = s.free {
                            CapacityBar(total: total, free: free, needed: s.bytes).frame(maxWidth: 220)
                        }
                        Spacer()
                        Text(s.spaceProblem ? "Short of \(byteText(s.bytes - (s.free ?? 0)))" : "\(s.copy) new · \(s.skip) already there")
                            .font(.callout)
                            .foregroundStyle(s.spaceProblem ? Color.red : .secondary)
                    }
                }
                if let c = plan.spec.cloud {
                    HStack(spacing: 10) {
                        Image(systemName: "icloud.fill").foregroundStyle(.blue).frame(width: 22)
                        Text("Google Drive").fontWeight(.medium)
                        Spacer()
                        Text("uploaded to \(c.remote == Cloud.ownRemote + ":" ? "akun Google di BCKUP" : c.target), then MD5-checked").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            if plan.renamedCount > 0 {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(plan.renamedCount) files with the same name but different contents are already in this roll.").fontWeight(.medium)
                        Text("Usually a card that was formatted and reused. To keep the card's structure intact, use a new roll name. If you go on, those files get a _2 suffix.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Use roll \"\(job.suggestedNewRoll)\" and check again") {
                            job.roll = job.suggestedNewRoll
                            job.check()
                        }
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            if plan.filesToCopy == 0 && !plan.items.isEmpty {
                Label("Every file on the card is already at the destination. Nothing needs copying.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }

            FileTable(rows: plan.items.map { item in
                let copy = item.needsCopy
                return FileRowData(rel: item.file.rel, kind: item.file.kind, size: item.file.size,
                                   status: copy ? (item.isRenamed ? "New (gets _2)" : "To copy") : "Already there",
                                   category: copy ? .todo : .existing, url: item.file.url)
            })
        }
    }
}

// MARK: - File table

struct FileRowData: Identifiable {
    enum Category: String, CaseIterable, Identifiable {
        case all = "All", todo = "To copy", existing = "Already there", failed = "Failed"
        var id: String { rawValue }
        var color: Color {
            switch self {
            case .all: return .secondary
            case .todo: return .accentColor
            case .existing: return .green
            case .failed: return .red
            }
        }
    }
    var id: String { rel }
    let rel: String
    let kind: FileKind
    let size: Int64
    let status: String
    let category: FileRowData.Category
    var url: URL? = nil
}

struct FileTable: View {
    let rows: [FileRowData]
    var subject = "Footage"
    var startExpanded = false
    @State private var filter: FileRowData.Category = .all
    @State private var expanded: Bool? = nil
    @State private var selection = Set<String>()

    var body: some View {
        let isOpen = expanded ?? startExpanded
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded = !isOpen }
                } label: {
                    Label("Files", systemImage: isOpen ? "chevron.down" : "chevron.right")
                        .fontWeight(.medium)
                }
                .buttonStyle(.plain)
                if isOpen && !selection.isEmpty {
                    Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
                    ShareButton(urls: selectedURLs, subject: subject, title: "Share")
                        .controlSize(.small)
                }
                Spacer()
                if isOpen {
                    Picker("", selection: $filter) {
                        ForEach(categories) { c in
                            Text("\(c.rawValue) \(count(c))").tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            if isOpen {
                Table(of: FileRowData.self, selection: $selection) {
                    TableColumn("") { r in
                        Image(systemName: r.kind.symbol).foregroundStyle(.secondary)
                    }
                    .width(18)
                    TableColumn("File") { r in
                        Text(r.rel).lineLimit(1).truncationMode(.middle).help(r.rel)
                    }
                    TableColumn("Size") { r in
                        Text(byteText(r.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(80)
                    TableColumn("Status") { r in
                        Text(r.status).foregroundStyle(r.category.color).lineLimit(1).help(r.status)
                    }
                    .width(min: 120, ideal: 170)
                } rows: {
                    ForEach(filtered) { r in
                        TableRow(r)
                            .itemProvider { r.url.flatMap { NSItemProvider(contentsOf: $0) } }
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    ShareMenuItems(urls: urls(for: ids), subject: subject)
                } primaryAction: { ids in
                    let u = urls(for: ids)
                    if !u.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(u) }
                }
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Drag files into another app (Premiere, DaVinci, Finder), or right-click to share.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var selectedURLs: [URL] { urls(for: selection) }

    private func urls(for ids: Set<String>) -> [URL] {
        rows.filter { ids.contains($0.id) }.compactMap(\.url)
    }

    private var categories: [FileRowData.Category] {
        FileRowData.Category.allCases.filter { $0 == .all || count($0) > 0 }
    }

    private func count(_ c: FileRowData.Category) -> Int {
        c == .all ? rows.count : rows.filter { $0.category == c }.count
    }

    private var filtered: [FileRowData] {
        let r = filter == .all ? rows : rows.filter { $0.category == filter }
        return Array(r.prefix(5000))
    }
}

// MARK: - Progress

struct ProgressPanel: View {
    @ObservedObject var job: OffloadJob

    var body: some View {
        let p = job.progress
        Panel {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.stage == .uploading ? "Upload to Google Drive" : "Copying & verifying")
                        .font(.headline)
                    Text(phaseText(p)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(p.total > 0 ? "\(Int(p.fraction * 100))%" : "…")
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if p.total > 0 {
                ProgressView(value: p.fraction).controlSize(.large)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack(spacing: 10) {
                if p.isBytes {
                    StatTile(value: byteText(p.done), label: "of \(byteText(p.total)) (copy + check)")
                    StatTile(value: job.speed > 1 ? "\(byteText(Int64(job.speed)))/s" : "…", label: "speed")
                    StatTile(value: remaining(p), label: "time left")
                    StatTile(value: p.fileCount > 0 ? "\(p.fileIndex)/\(p.fileCount)" : "…", label: "file")
                } else {
                    Text(p.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            if p.isBytes && !p.fileName.isEmpty {
                Label(p.fileName, systemImage: "doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("The card is only read. If you cancel, unfinished files are not saved under their real names.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func phaseText(_ p: EngineProgress) -> String {
        switch p.phase {
        case "Copying": return "Copying from the card to every destination at once"
        case "Memverifikasi": return "Reading the copies back and comparing hashes"
        default: return p.phase
        }
    }

    private func remaining(_ p: EngineProgress) -> String {
        guard job.speed > 1, p.total > p.done else { return "…" }
        return durationText(Double(p.total - p.done) / job.speed)
    }
}

func durationText(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s) s" }
    if s < 3600 { return "\(s / 60) min \(s % 60) s" }
    return "\(s / 3600) h \((s % 3600) / 60) min"
}

// MARK: - Result

struct ResultPanel: View {
    @ObservedObject var job: OffloadJob
    let result: OffloadResult

    var body: some View {
        let v = result.verdict
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(v.color).frame(width: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(v.title).font(.title.weight(.semibold)).foregroundStyle(v.color)
                    Text(v.detail).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 14)
                .padding(.vertical, 2)
            }
            .fixedSize(horizontal: false, vertical: true)

            Panel(title: "Copies", symbol: "square.stack.3d.up") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(result.spec.destinations, id: \.self) { d in
                        let ok = result.items.filter { $0.outcomes[d]?.isSafe == true }.count
                        let all = ok == result.items.count
                        HStack(spacing: 10) {
                            Image(systemName: all ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(all ? Color.green : .orange)
                            Text(volumeName(forPath: d)).fontWeight(.medium)
                            Text(d == result.spec.destinations.first ? "Main" : "Backup").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(ok) of \(result.items.count) files verified").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let m = result.cloudMessage {
                        HStack(spacing: 10) {
                            Image(systemName: result.cloudOK == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(result.cloudOK == true ? Color.green : .red)
                            Text("Google Drive").fontWeight(.medium)
                            Spacer()
                            Text(m).font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                        }
                    }
                }
                HStack(spacing: 10) {
                    StatTile(value: "\(result.copiedCount)", label: "copied · \(byteText(result.copiedBytes))", tint: .accentColor)
                    StatTile(value: "\(result.existingOnlyCount)", label: "already there", tint: .green)
                    StatTile(value: "\(result.failures)", label: "failed", tint: result.failures > 0 ? .red : .primary)
                    if let a = result.startedAt, let b = result.finishedAt {
                        StatTile(value: durationText(b.timeIntervalSince(a)), label: "time")
                    }
                }
                HStack(spacing: 14) {
                    Button { job.revealProject() } label: { Label("Show in Finder", systemImage: "folder") }
                    if !result.reports.isEmpty {
                        Button { job.openReport() } label: { Label("Open report", systemImage: "doc.text") }
                    }
                }
                .buttonStyle(.link)
                Divider()
                HStack(spacing: 10) {
                    Text("Share").fontWeight(.medium)
                    ShareButton(urls: job.projectFolderURL.map { [$0] } ?? [], subject: job.shareSubject, title: "Project folder")
                    ShareButton(urls: job.rollFolderURLs, subject: job.shareSubject, title: job.rollFolderURLs.count > 1 ? "Roll folders (\(job.rollFolderURLs.count))" : "Roll folder")
                    ShareButton(urls: result.items.compactMap { job.localURL(for: $0) }, subject: job.shareSubject, title: "All files")
                    Spacer()
                }
                Text("AirDrop, WhatsApp, Email or a Google Drive link. Big videos are best sent as a Google Drive link.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            let failedOrAll = result.items.map { item -> FileRowData in
                let fail = item.outcomes.values.compactMap { o -> String? in
                    if case .failed(let m) = o { return m } else { return nil }
                }.first
                let copied = item.outcomes.values.contains { if case .copied = $0 { return true } else { return false } }
                return FileRowData(rel: item.file.rel, kind: item.file.kind, size: item.file.size,
                                   status: fail ?? (copied ? "Copied & verified" : "Already there"),
                                   category: fail != nil ? .failed : (copied ? .todo : .existing),
                                   url: job.localURL(for: item))
            }
            Panel { FileTable(rows: failedOrAll, subject: job.shareSubject, startExpanded: result.failures > 0) }
        }
    }
}

struct JobSummary: View {
    @ObservedObject var job: OffloadJob

    private var summaryLine: String {
        var parts = job.activeDestinations.map { volumeName(forPath: $0) }
        if job.useCloud && job.settings.cloudEnabled { parts.append("Google Drive") }
        let mode = job.skipExisting ? (job.checkMode == .thorough ? "skip what's there, hash check" : "skip what's there, quick check") : "copy everything"
        return "To " + parts.joined(separator: ", ") + "  ·  " + mode
    }

    var body: some View {
        Panel(title: "Detail", symbol: "info.circle") {
            PathBreadcrumb(job: job)
            Text(summaryLine).font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Verdict styling

extension Verdict {
    var color: Color {
        switch self {
        case .safe: return .green
        case .oneCopy, .unverified: return .orange
        case .failed: return .red
        case .cancelled, .empty: return .gray
        }
    }

    var symbol: String {
        switch self {
        case .safe: return "checkmark.seal.fill"
        case .oneCopy: return "exclamationmark.shield.fill"
        case .unverified: return "questionmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle.fill"
        case .empty: return "tray"
        }
    }
}
