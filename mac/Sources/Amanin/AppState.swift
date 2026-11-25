import AppKit
import Foundation
import SwiftUI

struct VolumeInfo: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let name: String
    let uuid: String
    let isCard: Bool
    let capacity: Int64
    let format: String

    var subtitle: String {
        [capacity > 0 ? byteText(capacity) : nil, format.isEmpty ? nil : format].compactMap { $0 }.joined(separator: " · ")
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            if settings.primaryRoot != oldValue.primaryRoot || settings.backupRoots != oldValue.backupRoots || settings.hiddenVolumes != oldValue.hiddenVolumes {
                refreshVolumes(newlyMounted: nil)
            }
        }
    }
    @Published var cards: [VolumeInfo] = []
    @Published var otherVolumes: [VolumeInfo] = []
    @Published var manualSources: [URL] = []
    @Published var selection: URL?
    /// Loose files/folders dragged in, keyed by a synthetic source URL.
    @Published var dropSets: [URL: [URL]] = [:]
    @Published var dropTargeted = false
    let share = ShareCenter()
    let projectsModel = ProjectsModel()
    var statusBar: StatusBarController?
    @Published var notices: [Notice] = []
    let downloadsModel = DownloadsModel()

    let catalog: Catalog
    private(set) var jobs: [URL: OffloadJob] = [:]
    var openMainWindow: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        settings = AppSettings.load()
        catalog = Catalog(url: Catalog.defaultURL)
        projectsModel.app = self
        downloadsModel.app = self
        refreshVolumes(newlyMounted: nil)
        if selection == nil { selection = cards.first?.url }
        if selection == nil { selection = Nav.home }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusBar = StatusBarController(app: self)
            for c in self.cards { self.job(for: c.url).scanIfNeeded() }
        }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--nav-projects") { selection = Nav.projects }
        if args.contains("--nav-downloads") { selection = Nav.downloads }

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in self?.refreshVolumes(newlyMounted: url) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshVolumes(newlyMounted: nil) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .amaninOpenURLs, object: nil, queue: .main) { [weak self] note in
            let urls = note.object as? [URL] ?? []
            Task { @MainActor in
                self?.addDropped(urls)
                self?.showMainWindow()
            }
        })
    }

    // MARK: Drag & drop sources

    func addDropped(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL).map(\.standardizedFileURL)
        guard !fileURLs.isEmpty else { return }
        if fileURLs.count == 1 {
            let u = fileURLs[0]
            // A card icon dragged in from the desktop/Finder.
            if let v = (cards + otherVolumes).first(where: { $0.url.standardizedFileURL.path == u.path }) {
                selection = v.url
                return
            }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                if !manualSources.contains(u) { manualSources.append(u) }
                selection = u
                return
            }
        }
        let key = URL(string: "amanin-drop://set/\(UUID().uuidString)")!
        dropSets[key] = fileURLs
        manualSources.append(key)
        selection = key
    }

    func sourceName(_ u: URL) -> String {
        if let items = dropSets[u] {
            return items.count == 1 ? items[0].lastPathComponent : "\(items.count) dropped items"
        }
        return u.lastPathComponent
    }

    func sourceSubtitle(_ u: URL) -> String {
        if let items = dropSets[u] { return items.first?.deletingLastPathComponent().path ?? "" }
        return u.deletingLastPathComponent().path
    }

    var destinationRoots: [String] {
        ([settings.primaryRoot].compactMap { $0 } + settings.backupRoots)
    }

    // MARK: Volumes

    func refreshVolumes(newlyMounted: URL?) {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeUUIDStringKey,
                                      .volumeTotalCapacityKey, .volumeIsRootFileSystemKey, .volumeLocalizedFormatDescriptionKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let dests = destinationRoots.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        var c: [VolumeInfo] = []
        var o: [VolumeInfo] = []
        for u in urls {
            guard let rv = try? u.resourceValues(forKeys: Set(keys)) else { continue }
            if rv.volumeIsRootFileSystem == true { continue }
            guard rv.volumeIsRemovable == true || rv.volumeIsEjectable == true || rv.volumeIsInternal == false else { continue }
            let path = u.standardizedFileURL.path
            if dests.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) { continue }
            if (NSHomeDirectory() == path || NSHomeDirectory().hasPrefix(path + "/")) { continue }
            let uuid = rv.volumeUUIDString ?? path
            if settings.hiddenVolumes.contains(uuid) { continue }
            let info = VolumeInfo(url: u, name: rv.volumeName ?? u.lastPathComponent, uuid: uuid,
                                  isCard: CardScanner.looksLikeCard(u), capacity: Int64(rv.volumeTotalCapacity ?? 0),
                                  format: rv.volumeLocalizedFormatDescription ?? "")
            if info.isCard { c.append(info) } else { o.append(info) }
        }
        cards = c
        otherVolumes = o

        let present = Set(c.map(\.url) + o.map(\.url) + manualSources + Nav.all)
        for (k, j) in jobs where !present.contains(k) && !j.isBusy { jobs[k] = nil }
        if let sel = selection, !present.contains(sel) { selection = nil }

        if let n = newlyMounted?.standardizedFileURL.path,
           let card = c.first(where: { $0.url.standardizedFileURL.path == n }) {
            job(for: card.url).scanIfNeeded()
            if selection == nil || selection == Nav.home { selection = card.url }
            if settings.autoOpenOnCard { statusBar?.show() }
        }
    }

    func showMainWindow() {
        if let open = openMainWindow {
            open()
        } else {
            NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true }?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func notify(_ text: String) {
        notices.append(Notice(text: text))
        if notices.count > 3 { notices.removeFirst() }
    }

    /// Every mounted drive with what BCKUP uses it for (cards are listed separately).
    func pluggedDrives() -> [(name: String, role: String, url: URL)] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRootFileSystemKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsInternalKey, .volumeUUIDStringKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let cardPaths = Set(cards.map { $0.url.standardizedFileURL.path })
        var out: [(String, String, URL)] = []
        for u in urls {
            guard let rv = try? u.resourceValues(forKeys: Set(keys)), rv.volumeIsRootFileSystem != true else { continue }
            guard rv.volumeIsEjectable == true || rv.volumeIsRemovable == true || rv.volumeIsInternal == false else { continue }
            let path = u.standardizedFileURL.path
            if cardPaths.contains(path) { continue }
            if settings.hiddenVolumes.contains(rv.volumeUUIDString ?? path) { continue }
            let name = rv.volumeName ?? u.lastPathComponent
            func on(_ root: String?) -> Bool { root.map { $0 == path || $0.hasPrefix(path + "/") } ?? false }
            let role: String
            if on(settings.primaryRoot) { role = "Working drive" }
            else if settings.backupRoots.contains(where: { on($0) }) { role = "Backup drive" }
            else if (NSHomeDirectory() == path || NSHomeDirectory().hasPrefix(path + "/")) { role = "System disk" }
            else { role = "Not used" }
            out.append((name, role, u))
        }
        return out
    }

    func hide(_ v: VolumeInfo) {
        settings.hiddenVolumes.append(v.uuid)
    }

    func job(for url: URL) -> OffloadJob {
        if let j = jobs[url] { return j }
        let name = cards.first { $0.url == url }?.name ?? otherVolumes.first { $0.url == url }?.name ?? sourceName(url)
        let j = OffloadJob(source: url, app: self, isVolume: !manualSources.contains(url), name: name, items: dropSets[url])
        jobs[url] = j
        return j
    }

    func existingJob(for url: URL) -> OffloadJob? { jobs[url] }

    var isBusy: Bool { jobs.values.contains(where: \.isBusy) }

    var menuSymbol: String {
        if isBusy { return "arrow.triangle.2.circlepath" }
        return cards.isEmpty ? "sdcard" : "sdcard.fill"
    }

    var busyPercent: Int? {
        guard let j = jobs.values.first(where: { $0.stage == .copying || $0.stage == .uploading }) else { return nil }
        return Int(j.progress.fraction * 100)
    }

    var busyDescription: String? {
        guard let j = jobs.values.first(where: \.isBusy) else { return nil }
        return "\(j.displayName): \(j.statusText)"
    }

    // MARK: Pickers

    private func pickFolder(title: String, prompt: String) -> URL? {
        let p = NSOpenPanel()
        p.title = title
        p.prompt = prompt
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        return p.runModal() == .OK ? p.url : nil
    }

    func choosePrimary() {
        guard let u = pickFolder(title: "Main footage folder", prompt: "Use this folder") else { return }
        let path = u.standardizedFileURL.path
        settings.backupRoots.removeAll { $0 == path }
        settings.primaryRoot = path
    }

    func addBackup() {
        guard let u = pickFolder(title: "Backup folder (on another drive)", prompt: "Add as backup") else { return }
        let path = u.standardizedFileURL.path
        guard path != settings.primaryRoot, !settings.backupRoots.contains(path) else { return }
        settings.backupRoots.append(path)
    }

    func removeBackup(_ path: String) {
        settings.backupRoots.removeAll { $0 == path }
    }

    func chooseManualSource() {
        guard let u = pickFolder(title: "Choose a card or source folder", prompt: "Choose") else { return }
        if !manualSources.contains(u) { manualSources.append(u) }
        selection = u
    }

    func removeManual(_ u: URL) {
        manualSources.removeAll { $0 == u }
        dropSets[u] = nil
        if jobs[u]?.isBusy != true { jobs[u] = nil }
        if selection == u { selection = nil }
    }
}

// MARK: - One offload job per card / folder

@MainActor
final class OffloadJob: ObservableObject {
    enum Stage: Equatable {
        case idle, scanning, ready, planning, planned, copying, uploading, done
        case error(String)
    }

    let source: URL
    let isVolume: Bool
    let displayName: String
    let items: [URL]?
    weak var app: AppState?

    @Published var stage: Stage = .idle { didSet { app?.objectWillChange.send() } }
    @Published var scan: CardScan?
    @Published var plan: OffloadPlan?
    @Published var result: OffloadResult?
    @Published var progress = EngineProgress()
    @Published var speed: Double = 0

    @Published var client = "" { didSet { fieldChanged() } }
    @Published var project = "" { didSet { fieldChanged() } }
    @Published var date = Date() { didSet { fieldChanged() } }
    @Published var roll = "" { didSet { fieldChanged() } }
    @Published var backupOn: [String: Bool] = [:] { didSet { fieldChanged() } }
    @Published var useCloud: Bool { didSet { fieldChanged() } }
    @Published var skipExisting: Bool { didSet { fieldChanged() } }
    @Published var checkMode: CheckMode { didSet { fieldChanged() } }
    @Published var separateByType: Bool { didSet { fieldChanged() } }

    private var cancelFlag = CancelFlag()
    private var lastSample: (t: CFAbsoluteTime, done: Int64)?

    init(source: URL, app: AppState, isVolume: Bool, name: String, items: [URL]? = nil) {
        self.source = source
        self.items = items
        self.app = app
        self.isVolume = isVolume
        self.displayName = name
        useCloud = app.settings.cloudEnabled
        skipExisting = app.settings.skipExisting
        checkMode = app.settings.checkMode
        separateByType = app.settings.separateByType
    }

    var settings: AppSettings { app?.settings ?? AppSettings() }

    var isBusy: Bool {
        switch stage {
        case .scanning, .planning, .copying, .uploading: return true
        default: return false
        }
    }

    private func fieldChanged() {
        if stage == .planned {
            plan = nil
            stage = .ready
        }
    }

    // MARK: Folder naming

    private func subfolders(_ path: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return names.filter { n in
            guard !n.hasPrefix("."), n != "_BCKUP Reports", n != "_Laporan BCKUP", n != "_Laporan Amanin" else { return false }
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: path + "/" + n, isDirectory: &d) && d.boolValue
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var existingClients: [String] {
        guard settings.useClientFolder, let p = settings.primaryRoot else { return [] }
        return subfolders(p)
    }

    var existingProjects: [String] {
        guard let p = settings.primaryRoot else { return [] }
        if settings.useClientFolder {
            let c = cleanName(client)
            return c.isEmpty ? [] : subfolders(p + "/" + c)
        }
        return subfolders(p)
    }

    var projectExists: Bool { !cleanName(project).isEmpty && existingProjects.contains(cleanName(project)) }

    var projectFolder: String {
        projectExists ? cleanName(project) : settings.projectFolderName(project: project, date: date)
    }

    var connectedBackups: [String] {
        settings.backupRoots.filter { FileManager.default.fileExists(atPath: $0) }
    }

    var activeDestinations: [String] {
        guard let p = settings.primaryRoot, FileManager.default.fileExists(atPath: p) else { return [] }
        return [p] + connectedBackups.filter { backupOn[$0] ?? true }
    }

    func backupBinding(_ path: String) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.backupOn[path] ?? true },
                set: { [weak self] in self?.backupOn[path] = $0 })
    }

    var validationIssue: String? {
        guard let p = settings.primaryRoot else { return "Choose a main folder first" }
        if !FileManager.default.fileExists(atPath: p) { return "The main folder isn't connected. Plug in its drive first." }
        if settings.useClientFolder && cleanName(client).isEmpty { return "Enter a client name" }
        if cleanName(project).isEmpty { return "Enter a project name" }
        if cleanName(roll).isEmpty { return "Enter a roll name" }
        if useCloud && settings.cloudEnabled, let issue = settings.cloudIssue {
            return issue
        }
        return nil
    }

    func makeSpec() -> OffloadSpec {
        let cloud: CloudSpec? = (useCloud && settings.cloudEnabled) ? settings.cloudSpec() : nil
        return OffloadSpec(
            source: scan?.root ?? source,
            clientFolder: settings.useClientFolder ? cleanName(client) : nil,
            projectFolder: projectFolder,
            roll: cleanName(roll),
            destinations: activeDestinations,
            separateByType: separateByType,
            kindFolders: settings.kindFolders,
            skipExisting: skipExisting,
            checkMode: checkMode,
            cloud: cloud
        )
    }

    var previewPath: String {
        let root = settings.primaryRoot ?? "…"
        let spec = makeSpec()
        let sample = scan?.files.first { $0.kind == .video } ?? scan?.files.first
        let kind: FileKind = sample.map { Router.route([$0])[$0.rel] ?? .video } ?? .video
        let fileRel = sample.map { spec.targetRel(for: $0, routed: kind) } ?? spec.projectRel
        return root + "/" + fileRel
    }

    struct Crumb { let text: String; let isNew: Bool }

    /// Folder path for this offload, each level marked if it still has to be created.
    var breadcrumb: [Crumb] {
        guard let root = settings.primaryRoot else { return [] }
        let spec = makeSpec()
        var levels: [String] = []
        if let c = spec.clientFolder { levels.append(c.isEmpty ? "Client" : c) }
        levels.append(spec.projectFolder.isEmpty ? "Project" : spec.projectFolder)
        if spec.separateByType {
            let kinds = Set((scan?.files ?? []).map { Router.route([$0])[$0.rel] ?? .video })
            let names = [FileKind.video, .photo, .audio].filter { kinds.contains($0) }.compactMap { spec.kindFolders[$0] }
            if !names.isEmpty { levels.append(names.joined(separator: " · ")) }
        }
        levels.append(spec.roll.isEmpty ? "Roll" : spec.roll)
        var out = [Crumb(text: (root as NSString).lastPathComponent, isNew: false)]
        var path = root
        var missing = false
        for l in levels {
            path += "/" + (l.components(separatedBy: " · ").first ?? l)
            if !missing && !FileManager.default.fileExists(atPath: path) { missing = true }
            out.append(Crumb(text: l, isNew: missing))
        }
        return out
    }

    // MARK: Sharing helpers

    var shareSubject: String {
        let spec = result?.spec ?? makeSpec()
        return [spec.clientFolder, spec.projectFolder, spec.roll].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " – ")
    }

    /// Where an offloaded file now lives on the primary drive (falls back to the card).
    func localURL(for item: ItemResult) -> URL? {
        if let root = result?.spec.destinations.first, let rel = item.outcomes[root]?.rel {
            let u = URL(fileURLWithPath: root).appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return FileManager.default.fileExists(atPath: item.file.url.path) ? item.file.url : nil
    }

    var projectFolderURL: URL? {
        guard let r = result, let root = r.spec.destinations.first else { return nil }
        let u = URL(fileURLWithPath: root).appendingPathComponent(r.spec.projectRel)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    var rollFolderURLs: [URL] {
        guard let r = result, let root = r.spec.destinations.first, !r.spec.roll.isEmpty else { return [] }
        var out = Set<String>()
        for item in r.items {
            guard let rel = item.outcomes[root]?.rel else { continue }
            let comps = rel.split(separator: "/").map(String.init)
            if let i = comps.firstIndex(of: r.spec.roll) {
                out.insert(comps.prefix(i + 1).joined(separator: "/"))
            }
        }
        return out.sorted().map { URL(fileURLWithPath: root).appendingPathComponent($0) }
    }

    var suggestedNewRoll: String {
        let r = cleanName(roll)
        if let m = r.range(of: #"\d+$"#, options: .regularExpression), let n = Int(r[m]) {
            return String(r[..<m.lowerBound]) + String(format: "%0\(r[m].count)d", n + 1)
        }
        return r + " 2"
    }

    // MARK: Stages

    func scanIfNeeded() {
        if stage == .idle { rescan() }
    }

    func rescan() {
        stage = .scanning
        scan = nil
        plan = nil
        result = nil
        let src = source
        let items = self.items
        let name = displayName
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let s = try items.map { try CardScanner.scan(items: $0, name: name) } ?? CardScanner.scan(src)
                await MainActor.run { self?.applyScan(s) }
            } catch {
                await MainActor.run { self?.stage = .error(error.localizedDescription) }
            }
        }
    }

    // MARK: Quick check (runs by itself when a card goes in; reads nothing but the card and the catalog)

    @Published var quick: OffloadPlan?
    @Published var quickVerified = false
    @Published var quickRunning = false
    @Published var quickProgress = EngineProgress()

    func runQuickCheck(thorough: Bool = false) {
        guard let scan, let app, settings.primaryRoot != nil, !quickRunning, !isBusy else { return }
        var spec = makeSpec()
        guard !spec.destinations.isEmpty else { return }
        if spec.projectFolder.isEmpty { spec.projectFolder = "_cek" }
        if spec.roll.isEmpty { spec.roll = "_cek" }
        spec.skipExisting = true
        spec.checkMode = thorough ? .thorough : .fast
        spec.cloud = nil
        quickRunning = true
        let engine = OffloadEngine(catalog: app.catalog, cancel: CancelFlag())
        let throttle = Throttle(interval: 0.2)
        Task.detached(priority: .utility) { [weak self] in
            do {
                let p = try engine.plan(spec: spec, scan: scan) { pr in
                    if throttle.allow() { Task { @MainActor in self?.quickProgress = pr } }
                }
                await MainActor.run {
                    self?.quick = p
                    self?.quickVerified = thorough
                    self?.quickRunning = false
                    self?.app?.objectWillChange.send()
                }
            } catch {
                let msg = error.localizedDescription
                await MainActor.run {
                    self?.quickRunning = false
                    self?.app?.notify("\(self?.displayName ?? "Card"): \(msg). Nothing was changed.")
                }
            }
        }
    }

    struct CardStatus {
        let title: String
        let headline: String
        let detail: String
        let color: Color
        let symbol: String
        let safe: Bool
    }

    /// One summary for the menu-bar panel and home screen: the finished offload if there is one, otherwise the quick check.
    var cardStatus: CardStatus? {
        if stage == .copying || stage == .uploading {
            return CardStatus(title: "Copying \(Int(progress.fraction * 100))%", headline: "Copying now",
                              detail: "Don't unplug the card until it's done.", color: .accentColor, symbol: "arrow.down.circle", safe: false)
        }
        if stage == .done, let r = result {
            let v = r.verdict
            let where_ = r.spec.destinations.map { volumeName(forPath: $0) }.joined(separator: " and ")
            return CardStatus(title: v.title, headline: "On \(where_)", detail: v.detail, color: v.color, symbol: v.symbol, safe: v.isGood)
        }
        guard let p = quick else {
            if quickRunning || stage == .scanning { return CardStatus(title: "Checking…", headline: "Comparing with your drives", detail: "Comparing the card with your drives.", color: .secondary, symbol: "hourglass", safe: false) }
            return nil
        }
        if p.items.isEmpty { return CardStatus(title: "Empty card", headline: "No files", detail: "There are no files on this card.", color: .secondary, symbol: "tray", safe: false) }
        let full = p.summaries.filter { $0.copy == 0 }.map { volumeName(forPath: $0.root) }
        let nowhere = p.items.filter { item in !item.actions.values.contains { if case .skip = $0 { return true } else { return false } } }.count
        let fullText = full.joined(separator: " and ")
        if full.count >= 2 && quickVerified {
            return CardStatus(title: "Safe to format", headline: "All on \(fullText)",
                              detail: "Every file on this card has a checked copy on \(fullText).", color: .green, symbol: "checkmark.circle.fill", safe: true)
        }
        if full.count >= 2 {
            return CardStatus(title: "Looks backed up", headline: "All on \(fullText)",
                              detail: "Every file was found on \(fullText) by name, size and date. Check the contents to be sure before formatting.", color: .orange, symbol: "checkmark.circle", safe: false)
        }
        if full.count == 1 {
            return CardStatus(title: "Only 1 copy", headline: "All on \(fullText)",
                              detail: "Every file is on \(fullText). Keep a second copy before you format.", color: .orange, symbol: "exclamationmark.circle.fill", safe: false)
        }
        return CardStatus(title: "\(p.filesToCopy) files not copied yet", headline: "\(nowhere) files aren't on any drive yet",
                          detail: "Copy this card before you format it.", color: .red, symbol: "xmark.circle.fill", safe: false)
    }

    private func applyScan(_ s: CardScan) {
        scan = s
        date = s.suggestedDate
        if roll.isEmpty {
            if let items {
                roll = items.count == 1 ? cleanName(items[0].deletingPathExtension().lastPathComponent) : "Extras"
            } else {
                roll = defaultRoll(s)
            }
        }
        // Carry on with the last project when the next card comes in within a few days.
        let st = settings
        if client.isEmpty && project.isEmpty && !st.lastProject.isEmpty {
            let recent = abs(Date().timeIntervalSince1970 - st.lastUsed) < 3 * 86400
            if recent {
                client = st.lastClient
                project = st.lastProject
            } else if st.useClientFolder {
                client = st.lastClient
            }
        }
        stage = .ready
        runQuickCheck()
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--auto-check") && validationIssue == nil { check() }
    }

    private func defaultRoll(_ s: CardScan) -> String {
        let brand = s.camera.components(separatedBy: CharacterSet(charactersIn: " (/")).first ?? "Card"
        let generic: Set<String> = ["NO NAME", "UNTITLED", "EOS_DIGITAL", "CANON", "NIKON", "SONY", "LUMIX", "DJI", "GOPRO", "SD", "CARD", "INSTA360"]
        if s.root.path == "/" || generic.contains(s.name.uppercased()) || s.name.isEmpty {
            let t = dateFormatter("HH.mm").string(from: s.firstDate ?? Date())
            return "\(brand) \(t)"
        }
        return s.name.uppercased().contains(brand.uppercased()) ? s.name : "\(brand) \(s.name)"
    }

    private func reporter() -> (EngineProgress) -> Void {
        let throttle = Throttle(interval: 0.15)
        return { [weak self] p in
            guard throttle.allow(force: p.total > 0 && p.done >= p.total) else { return }
            DispatchQueue.main.async { self?.applyProgress(p) }
        }
    }

    private func applyProgress(_ p: EngineProgress) {
        let now = CFAbsoluteTimeGetCurrent()
        if p.phase != progress.phase && !(p.phase.hasPrefix("Copying") || p.phase.hasPrefix("Memverifikasi")) {
            speed = 0
            lastSample = nil
        }
        if p.isBytes {
            if let last = lastSample {
                if now - last.t >= 0.5 {
                    let inst = Double(p.done - last.done) / (now - last.t)
                    speed = speed == 0 ? inst : speed * 0.7 + inst * 0.3
                    lastSample = (now, p.done)
                }
            } else {
                lastSample = (now, p.done)
            }
        }
        let pctChanged = Int(p.fraction * 100) != Int(progress.fraction * 100)
        progress = p
        if pctChanged { app?.objectWillChange.send() }
    }

    func check() {
        guard validationIssue == nil, let scan, let app else { return }
        let spec = makeSpec()
        let flag = CancelFlag()
        cancelFlag = flag
        plan = nil
        result = nil
        progress = EngineProgress(phase: "Memulai…", isBytes: false)
        stage = .planning
        let engine = OffloadEngine(catalog: app.catalog, cancel: flag)
        let report = reporter()
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let p = try engine.plan(spec: spec, scan: scan, progress: report)
                await MainActor.run {
                    self?.plan = p
                    self?.stage = .planned
                    if ProcessInfo.processInfo.arguments.contains("--auto-start") { self?.start() }
                }
            } catch AppError.cancelled {
                await MainActor.run { self?.stage = .ready }
            } catch {
                await MainActor.run { self?.stage = .error(error.localizedDescription) }
            }
        }
    }

    func start() {
        guard let plan, let app else { return }
        app.settings.lastClient = client
        app.settings.lastProject = projectFolder
        app.settings.lastUsed = Date().timeIntervalSince1970
        let flag = CancelFlag()
        cancelFlag = flag
        speed = 0
        lastSample = nil
        progress = EngineProgress(phase: "Copying", isBytes: true)
        stage = .copying
        let engine = OffloadEngine(catalog: app.catalog, cancel: flag)
        let report = reporter()
        let started = Date()
        Task.detached(priority: .userInitiated) { [weak self] in
            var r = engine.execute(plan: plan, progress: report)
            if plan.spec.cloud != nil && !r.cancelled && r.failures == 0 {
                await MainActor.run {
                    self?.stage = .uploading
                    self?.speed = 0
                    self?.lastSample = nil
                }
                engine.upload(result: &r, progress: report)
            }
            r.startedAt = started
            r.finishedAt = Date()
            r.reports = Reporter.write(result: r, scan: plan.scan)
            let final = r
            await MainActor.run {
                self?.result = final
                self?.stage = .done
                self?.app?.projectsModel.projects = []
                NSSound(named: final.verdict.isGood ? "Glass" : "Basso")?.play()
            }
        }
    }

    func cancelWork() { cancelFlag.cancel() }

    func resetToReady() {
        plan = nil
        result = nil
        stage = scan == nil ? .idle : .ready
        if scan == nil { rescan() }
    }

    func eject() {
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: source)
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't eject the card"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    /// Card on the left, its destination folder on the right, in two Finder windows.
    func openSideBySide() {
        let left = scan?.root ?? source
        var right = URL(fileURLWithPath: settings.primaryRoot ?? NSHomeDirectory())
        let rel = result?.spec.projectRel ?? makeSpec().projectRel
        let candidate = right.appendingPathComponent(rel)
        if !rel.isEmpty, FileManager.default.fileExists(atPath: candidate.path) { right = candidate }
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = """
        tell application "Finder"
            activate
            set b to bounds of window of desktop
            set w to (item 3 of b) div 2
            set h to (item 4 of b) - 40
            set a to make new Finder window to (POSIX file "\(esc(left.path))" as alias)
            set bounds of a to {0, 60, w, h}
            set c to make new Finder window to (POSIX file "\(esc(right.path))" as alias)
            set bounds of c to {w, 60, (item 3 of b), h}
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err != nil {
            NSWorkspace.shared.open(left)
            NSWorkspace.shared.open(right)
        }
    }

    func revealProject() {
        guard let root = settings.primaryRoot else { return }
        let rel = result?.spec.projectRel ?? makeSpec().projectRel
        let u = URL(fileURLWithPath: root).appendingPathComponent(rel)
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: u.path) ? u : URL(fileURLWithPath: root))
    }

    func openReport() {
        guard let p = result?.reports.first(where: { $0.hasSuffix(".txt") }) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    var statusText: String {
        switch stage {
        case .idle: return "Not read yet"
        case .scanning: return "Reading the card…"
        case .ready: return "Ready to check"
        case .planning: return "Checking…"
        case .planned: return "Ready to copy"
        case .copying: return "Copying \(Int(progress.fraction * 100))%"
        case .uploading: return "Upload \(Int(progress.fraction * 100))%"
        case .done: return result?.verdict.title ?? "Done"
        case .error: return "Something went wrong"
        }
    }
}


extension Notification.Name {
    static let amaninOpenURLs = Notification.Name("amanin.openURLs")
}

struct Notice: Identifiable {
    let id = UUID()
    let text: String
}
