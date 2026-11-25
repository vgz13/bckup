import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - Special sidebar destinations

enum Nav {
    static let home = URL(string: "bckup://home")!
    static let projects = URL(string: "bckup://projects")!
    static let downloads = URL(string: "bckup://downloads")!
    static var all: [URL] { [home, projects, downloads] }
}

// MARK: - Thumbnails

final class ThumbCache: @unchecked Sendable {
    static let shared = ThumbCache()
    private let cache = NSCache<NSURL, NSImage>()
    func get(_ u: URL) -> NSImage? { cache.object(forKey: u as NSURL) }
    func set(_ u: URL, _ i: NSImage) { cache.setObject(i, forKey: u as NSURL) }
}

struct Thumb: View {
    let url: URL
    var size = CGSize(width: 150, height: 84)

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.secondary.opacity(0.12))
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: MediaTypes.kind(ofExtension: url.pathExtension).symbol)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            if let c = ThumbCache.shared.get(url) { image = c; return }
            let req = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                ThumbCache.shared.set(url, rep.nsImage)
                image = rep.nsImage
            }
        }
    }
}

/// Contact sheet of the photos and clips on a card.
struct CardPreview: View {
    @ObservedObject var job: OffloadJob
    @State private var showAll = false

    private var media: [CardFile] {
        (job.scan?.files ?? []).filter { f in
            (f.kind == .video || f.kind == .photo) && !f.rel.uppercased().contains("THMBNL/")
                && !["arw", "cr2", "cr3", "nef", "raf", "rw2", "orf", "dng"].contains(f.url.pathExtension.lowercased())
                || (f.kind == .photo && !hasJPEGTwin(f))
        }
    }

    private func hasJPEGTwin(_ f: CardFile) -> Bool {
        let stem = f.url.deletingPathExtension().path
        return ["JPG", "jpg", "JPEG", "HIF", "HEIC"].contains { FileManager.default.fileExists(atPath: stem + "." + $0) }
    }

    var body: some View {
        let items = media
        if !items.isEmpty {
            Panel(title: "On this card") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 10, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(items.prefix(showAll ? 400 : 18)) { f in
                        VStack(alignment: .leading, spacing: 3) {
                            Thumb(url: f.url)
                            Text(f.url.lastPathComponent)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(byteText(f.size)).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(width: 150, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(f.url) }
                        .onDrag { NSItemProvider(contentsOf: f.url) ?? NSItemProvider() }
                        .help("Double-click to open. Drag into another app to use this file.")
                    }
                }
                if items.count > 18 {
                    Button(showAll ? "Show fewer" : "Show all (\(min(items.count, 400)))") { showAll.toggle() }
                        .buttonStyle(.link)
                }
            }
        }
    }
}

// MARK: - Projects & backup checks

struct ProjectInfo: Identifiable {
    var id: String { rel }
    let client: String?
    let name: String
    let rel: String
    var files = 0
    var bytes: Int64 = 0
    var modified: Date?
    /// backup root → (missing files, missing bytes); nil means that backup has never been read.
    var missing: [String: (Int, Int64)?] = [:]

    func status(backups: [String]) -> (text: String, color: Color, needsBackup: Bool) {
        if backups.isEmpty { return ("No backup drive yet", .secondary, false) }
        if files == 0 { return ("Empty", .secondary, false) }
        var lacking: [String] = []
        var unknown = 0
        for b in backups {
            switch missing[b] {
            case .some(.some(let m)) where m.0 > 0: lacking.append("\(volumeName(forPath: b)): missing \(m.0)")
            case .some(.some): break
            default: unknown += 1
            }
        }
        if !lacking.isEmpty { return (lacking.joined(separator: ", "), .orange, true) }
        if unknown == backups.count { return ("Backup drive not read yet", .secondary, false) }
        return ("Complete on \(backups.count - unknown) backup", .green, false)
    }
}

@MainActor
final class ProjectsModel: ObservableObject {
    @Published var projects: [ProjectInfo] = []
    @Published var loading = false
    @Published var loadMessage = ""
    @Published var onlyMissing = false
    @Published var backingUp: String?
    @Published var progress = EngineProgress()
    @Published var lastMessage: String?
    private var cancel = CancelFlag()
    weak var app: AppState?

    func refresh() {
        guard let app, let primary = app.settings.primaryRoot, !loading else { return }
        loading = true
        loadMessage = "Reading the main folder…"
        let backups = app.settings.backupRoots
        let useClient = app.settings.useClientFolder
        let catalog = app.catalog
        Task.detached(priority: .userInitiated) { [weak self] in
            let fm = FileManager.default
            if fm.fileExists(atPath: primary) {
                try? catalog.refresh(root: primary, cancel: nil) { n in
                    Task { @MainActor in self?.loadMessage = "Reading the main folder… \(n) files" }
                }
            }
            for b in backups where fm.fileExists(atPath: b) {
                await MainActor.run { self?.loadMessage = "Reading \(volumeName(forPath: b))…" }
                try? catalog.refresh(root: b, cancel: nil) { _ in }
            }
            let list = ProjectsModel.compute(primary: primary, backups: backups, useClient: useClient, catalog: catalog)
            await MainActor.run {
                self?.projects = list
                self?.loading = false
                self?.loadMessage = ""
                if ProcessInfo.processInfo.arguments.contains("--auto-backup"), self?.backingUp == nil, self?.lastMessage == nil,
                   let p = list.first(where: { $0.status(backups: backups).needsBackup }) {
                    self?.backup(p)
                }
            }
        }
    }

    nonisolated static func listDirs(_ path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { n in
            var d: ObjCBool = false
            return !n.hasPrefix(".") && !n.hasPrefix("_Laporan") && n != "_BCKUP Reports" && FileManager.default.fileExists(atPath: path + "/" + n, isDirectory: &d) && d.boolValue
        }
    }

    nonisolated static func compute(primary: String, backups: [String], useClient: Bool, catalog: Catalog) -> [ProjectInfo] {
        var projects: [String: ProjectInfo] = [:]
        if useClient {
            for c in listDirs(primary) {
                for p in listDirs(primary + "/" + c) {
                    projects[c + "/" + p] = ProjectInfo(client: c, name: p, rel: c + "/" + p)
                }
            }
        } else {
            for p in listDirs(primary) { projects[p] = ProjectInfo(client: nil, name: p, rel: p) }
        }
        let depth = useClient ? 2 : 1
        func key(_ rel: String) -> String? {
            let comps = rel.split(separator: "/", maxSplits: depth, omittingEmptySubsequences: true)
            guard comps.count > depth else { return nil }
            return comps.prefix(depth).joined(separator: "/")
        }
        let primaryEntries = catalog.allEntries(root: primary)
        var byProject: [String: [Catalog.Entry]] = [:]
        for e in primaryEntries.values {
            guard let k = key(e.rel), projects[k] != nil else { continue }
            byProject[k, default: []].append(e)
        }
        let backupSets: [String: [String: Int64]?] = Dictionary(uniqueKeysWithValues: backups.map { b in
            let entries = catalog.allEntries(root: b)
            let connected = FileManager.default.fileExists(atPath: b)
            if entries.isEmpty && !connected { return (b, nil) }
            return (b, entries.mapValues(\.size))
        })
        for (k, entries) in byProject {
            projects[k]?.files = entries.count
            projects[k]?.bytes = entries.reduce(0) { $0 + $1.size }
            projects[k]?.modified = entries.map(\.mtime).max().map { Date(timeIntervalSince1970: $0) }
            for b in backups {
                guard let set = backupSets[b] ?? nil else { projects[k]?.missing[b] = .some(nil); continue }
                var n = 0
                var bytes: Int64 = 0
                for e in entries where set[e.rel] != e.size {
                    n += 1
                    bytes += e.size
                }
                projects[k]?.missing[b] = .some((n, bytes))
            }
        }
        return projects.values.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// Copies whatever a project is missing onto every connected backup drive, verified like a card offload.
    func backup(_ p: ProjectInfo) {
        guard let app, let primary = app.settings.primaryRoot, backingUp == nil else { return }
        let backups = app.settings.backupRoots.filter { FileManager.default.fileExists(atPath: $0) }
        guard !backups.isEmpty else {
            lastMessage = "Plug in a backup drive first."
            return
        }
        let flag = CancelFlag()
        cancel = flag
        backingUp = p.rel
        lastMessage = nil
        progress = EngineProgress(phase: "Reading the project…", isBytes: false)
        let catalog = app.catalog
        let folder = URL(fileURLWithPath: primary).appendingPathComponent(p.rel)
        let throttle = Throttle(interval: 0.2)
        Task.detached(priority: .userInitiated) { [weak self] in
            let report: (EngineProgress) -> Void = { pr in
                if throttle.allow() { Task { @MainActor in self?.progress = pr } }
            }
            var message: String
            do {
                let scan = try CardScanner.scan(folder, cancel: flag)
                let spec = OffloadSpec(source: folder, clientFolder: nil, projectFolder: p.rel, roll: "Project backup",
                                       destinations: backups, separateByType: false, kindFolders: [:],
                                       skipExisting: true, checkMode: .fast, cloud: nil, mirrorPrefix: p.rel)
                let engine = OffloadEngine(catalog: catalog, cancel: flag)
                let plan = try engine.plan(spec: spec, scan: scan, progress: report)
                var r = engine.execute(plan: plan, progress: report)
                r.finishedAt = Date()
                if r.copiedCount > 0 || r.failures > 0 { r.reports = Reporter.write(result: r, scan: scan) }
                if r.cancelled { message = "Backup of \(p.name) cancelled." }
                else if r.failures > 0 { message = "Backup of \(p.name): \(r.failures) files failed." }
                else { message = "Backup of \(p.name) done: \(r.copiedCount) files copied (\(byteText(r.copiedBytes)))." }
            } catch AppError.cancelled {
                message = "Backup of \(p.name) cancelled."
            } catch {
                message = "Backup of \(p.name) failed: \(error.localizedDescription)"
            }
            let msg = message
            await MainActor.run {
                self?.backingUp = nil
                self?.lastMessage = msg
                self?.refresh()
            }
        }
    }

    func cancelBackup() { cancel.cancel() }
}

struct ProjectsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: ProjectsModel
    @State private var selection = Set<String>()

    var body: some View {
        let backups = app.settings.backupRoots
        let rows = model.projects.filter { !model.onlyMissing || $0.status(backups: backups).needsBackup }
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Projects").font(.title.weight(.semibold))
                    Text(subtitle(backups)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Only not backed up", isOn: $model.onlyMissing)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Re-read the main folder and backup drives")
                    .disabled(model.loading)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Table(rows, selection: $selection) {
                TableColumn("Project") { p in Text(p.rel).fontWeight(.medium) }
                    .width(min: 140, ideal: 240)
                TableColumn("Size") { p in Text(byteText(p.bytes)).monospacedDigit().foregroundStyle(.secondary) }
                    .width(80)
                TableColumn("File") { p in Text("\(p.files)").monospacedDigit().foregroundStyle(.secondary) }
                    .width(50)
                TableColumn("Last changed") { p in
                    Text(p.modified.map { dateFormatter("dd.MM.yy HH.mm").string(from: $0) } ?? "–")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .width(110)
                TableColumn("Backup") { p in
                    let st = p.status(backups: backups)
                    HStack(spacing: 8) {
                        Text(model.backingUp == p.rel ? "Backing up…" : st.text)
                            .foregroundStyle(st.color)
                            .lineLimit(1)
                            .help(st.text)
                        if st.needsBackup && model.backingUp == nil {
                            Button("Backup") { model.backup(p) }
                                .controlSize(.small)
                        }
                    }
                }
                .width(min: 160, ideal: 260)
            }
            .frame(minHeight: 160, maxHeight: .infinity)
            .layoutPriority(1)
            .contextMenu(forSelectionType: String.self) { ids in
                let urls = urls(ids)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                if let p = rows.first(where: { ids.contains($0.rel) }), model.backingUp == nil {
                    Button("Back up now") { model.backup(p) }
                }
                Divider()
                ShareMenuItems(urls: urls)
            } primaryAction: { ids in
                urls(ids).forEach { NSWorkspace.shared.open($0) }
            }
            .overlay {
                if rows.isEmpty && !model.loading {
                    ContentUnavailableView(model.onlyMissing ? "Every project is backed up" : "No projects yet",
                                           systemImage: model.onlyMissing ? "checkmark" : "folder",
                                           description: Text(model.onlyMissing ? "Nothing is missing from the backup drives." : "Projects show up here after the first card is copied."))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar(rows: rows, backups: backups) }
        .navigationTitle("Projects")
        .onAppear { if model.projects.isEmpty { model.refresh() } }
    }

    private func subtitle(_ backups: [String]) -> String {
        let root = app.settings.primaryRoot.map { ($0 as NSString).lastPathComponent } ?? "-"
        let n = model.projects.count
        let lacking = model.projects.filter { $0.status(backups: backups).needsBackup }.count
        var s = "\(n) projects in \(root)"
        if !backups.isEmpty { s += lacking == 0 ? "  ·  all fully backed up" : "  ·  \(lacking) not fully backed up" }
        return s
    }

    private func urls(_ ids: Set<String>) -> [URL] {
        guard let root = app.settings.primaryRoot else { return [] }
        return ids.sorted().map { URL(fileURLWithPath: root).appendingPathComponent($0) }
    }

    @ViewBuilder private func bottomBar(rows: [ProjectInfo], backups: [String]) -> some View {
        HStack(spacing: 12) {
            if model.loading {
                ProgressView().controlSize(.small)
                Text(model.loadMessage).foregroundStyle(.secondary)
            } else if let b = model.backingUp {
                ProgressView(value: model.progress.fraction).frame(width: 180)
                Text("\(b): \(model.progress.phase)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Cancel") { model.cancelBackup() }
            } else {
                Text(model.lastMessage ?? "Backup status comes from what each backup drive held when it was last read, so it shows even when the drive isn't plugged in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                let lacking = rows.filter { $0.status(backups: backups).needsBackup }
                if let first = lacking.first {
                    Button("Backup \(lacking.count == 1 ? first.name : "yang paling baru")") { model.backup(first) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Sort downloads into a project's Assets folder

struct DLItem: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let size: Int64
    let date: Date
    let isFolder: Bool
}

@MainActor
final class DownloadsModel: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case downloads = "Downloads", desktop = "Desktop"
        var id: String { rawValue }
        var directory: FileManager.SearchPathDirectory { self == .downloads ? .downloadsDirectory : .desktopDirectory }
    }

    @Published var source: Source = .downloads
    @Published var items: [DLItem] = []
    @Published var days = 14
    @Published var targetProject = ""
    @Published var subfolder = "Assets"
    @Published var moveOriginals = false
    @Published var busy = false
    @Published var message: String?
    @Published var done = Set<URL>()
    weak var app: AppState?

    @Published var loading = false

    /// Lists recent files off the main thread (the first read can wait on macOS's folder-access prompt).
    func reload() {
        var dir = FileManager.default.urls(for: source.directory, in: .userDomainMask)[0]
        if let test = ProcessInfo.processInfo.environment["BCKUP_TEST_DOWNLOADS"] { dir = URL(fileURLWithPath: test) }
        let since = Date().addingTimeInterval(-Double(days) * 86400)
        loading = true
        Task.detached(priority: .userInitiated) { [weak self] in
            let keys: [URLResourceKey] = [.fileSizeKey, .addedToDirectoryDateKey, .contentModificationDateKey, .isDirectoryKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
            let partial: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]
            let found: [DLItem] = urls.compactMap { u in
                guard !partial.contains(u.pathExtension.lowercased()),
                      let rv = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
                let date = rv.addedToDirectoryDate ?? rv.contentModificationDate ?? .distantPast
                guard date >= since else { return nil }
                return DLItem(url: u, size: Int64(rv.fileSize ?? 0), date: date, isFolder: rv.isDirectory == true)
            }
            .sorted { $0.date > $1.date }
            await MainActor.run {
                self?.items = found
                self?.loading = false
            }
        }
    }

    var projectOptions: [String] {
        guard let app, let root = app.settings.primaryRoot else { return [] }
        if app.settings.useClientFolder {
            return ProjectsModel.listDirs(root).flatMap { c in ProjectsModel.listDirs(root + "/" + c).map { c + "/" + $0 } }
                .sorted { a, b in
                    let da = (try? FileManager.default.attributesOfItem(atPath: root + "/" + a)[.modificationDate] as? Date) ?? .distantPast
                    let db = (try? FileManager.default.attributesOfItem(atPath: root + "/" + b)[.modificationDate] as? Date) ?? .distantPast
                    return da > db
                }
        }
        return ProjectsModel.listDirs(root)
    }

    func copy(_ selected: [DLItem]) {
        guard let app, let root = app.settings.primaryRoot, !targetProject.isEmpty, !selected.isEmpty else { return }
        let destDir = URL(fileURLWithPath: root).appendingPathComponent(targetProject).appendingPathComponent(cleanName(subfolder).isEmpty ? "Assets" : cleanName(subfolder))
        let move = moveOriginals
        busy = true
        message = "Copying \(selected.count) items…"
        Task.detached(priority: .userInitiated) { [weak self] in
            var copied: [URL] = []
            var failed: [String] = []
            for item in selected {
                let sources: [(URL, String)]
                if item.isFolder {
                    let files = (try? CardScanner.scan(item.url))?.files ?? []
                    sources = files.map { ($0.url, item.url.lastPathComponent + "/" + $0.rel) }
                } else {
                    sources = [(item.url, item.url.lastPathComponent)]
                }
                var ok = true
                for (src, rel) in sources {
                    let target = destDir.appendingPathComponent(rel)
                    let mtime = (try? src.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                    // Already there with the same content: nothing to do.
                    if FileManager.default.fileExists(atPath: target.path),
                       let a = try? IO.hashFile(src.path, cancel: nil), let b = try? IO.hashFile(target.path, cancel: nil), a == b {
                        continue
                    }
                    do {
                        let r = try Copier.copy(src: src, targets: [target], mtime: mtime, cancel: CancelFlag()) { _, _ in }
                        if let e = r.errors.first ?? nil { ok = false; failed.append("\(src.lastPathComponent): \(e)") }
                    } catch {
                        ok = false
                        failed.append("\(src.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                if ok { copied.append(item.url) }
            }
            if move && !copied.isEmpty {
                _ = try? await NSWorkspace.shared.recycle(copied)
            }
            let c = copied, f = failed
            await MainActor.run {
                self?.busy = false
                self?.done.formUnion(c)
                var m = "\(c.count) items copied & checked into \(destDir.path.replacingOccurrences(of: root + "/", with: ""))."
                if move && !c.isEmpty { m += " Originals moved to the Bin." }
                if !f.isEmpty { m += " Failed: " + f.prefix(3).joined(separator: "; ") }
                self?.message = m
                if move { self?.reload() }
            }
        }
    }
}

struct DownloadsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: DownloadsModel
    @State private var selection = Set<URL>()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sort downloads").font(.title.weight(.semibold))
                Text("Put logos, music, briefs or client footage into a project folder. Files are only copied; originals go to the Bin only if you choose.")
                    .font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Picker("", selection: $model.source) {
                        ForEach(DownloadsModel.Source.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                    Picker("", selection: $model.days) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Table(model.items, selection: $selection) {
                TableColumn("Name") { i in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: i.url.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(i.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        if model.done.contains(i.url) {
                            Image(systemName: "checkmark").foregroundStyle(.green).help("Copied to the project")
                        }
                    }
                }
                TableColumn("Kind") { i in
                    Text(i.isFolder ? "Folder" : MediaTypes.kind(ofExtension: i.url.pathExtension).label).foregroundStyle(.secondary)
                }
                .width(70)
                TableColumn("Size") { i in
                    Text(i.isFolder ? "–" : byteText(i.size)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(80)
                TableColumn("Added") { i in
                    Text(dateFormatter("dd.MM HH.mm").string(from: i.date)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(90)
            }
            .frame(minHeight: 160, maxHeight: .infinity)
            .layoutPriority(1)
            .contextMenu(forSelectionType: URL.self) { ids in
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(Array(ids)) }
                Divider()
                ShareMenuItems(urls: Array(ids))
            } primaryAction: { ids in
                ids.forEach { NSWorkspace.shared.open($0) }
            }
            .overlay {
                if model.loading && model.items.isEmpty {
                    ProgressView("Reading \(model.source.rawValue)…")
                } else if model.items.isEmpty {
                    ContentUnavailableView("No new files", systemImage: "tray",
                                           description: Text("Nothing arrived in \(model.source.rawValue) in the last \(model.days) days."))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Picker("To", selection: $model.targetProject) {
                        Text("Choose a project…").tag("")
                        ForEach(model.projectOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(minWidth: 160, maxWidth: 300)
                    Text("/").foregroundStyle(.secondary)
                    TextField("Assets", text: $model.subfolder).frame(width: 90)
                    Spacer(minLength: 0)
                    if model.busy { ProgressView().controlSize(.small) }
                    Button(selection.isEmpty ? "Copy" : "Copy \(selection.count)") {
                        model.copy(model.items.filter { selection.contains($0.url) })
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty || model.targetProject.isEmpty || model.busy)
                }
                HStack(spacing: 8) {
                    Toggle("Move originals to the Bin after copying", isOn: $model.moveOriginals)
                    Spacer(minLength: 0)
                }
                if let m = model.message {
                    Text(m).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .navigationTitle("Sort downloads")
        .onAppear {
            model.reload()
            if model.targetProject.isEmpty, let last = app.settings.lastProjectRel, model.projectOptions.contains(last) {
                model.targetProject = last
            }
        }
        .onChange(of: model.source) { model.reload() }
        .onChange(of: model.days) { model.reload() }
    }
}
