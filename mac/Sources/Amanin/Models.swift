import Foundation

// MARK: - File kinds

enum FileKind: String, Codable, CaseIterable, Hashable {
    case video, photo, audio, sidecar, other

    var label: String {
        switch self {
        case .video: return "Video"
        case .photo: return "Photo"
        case .audio: return "Audio"
        case .sidecar: return "Sidecar"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .video: return "film"
        case .photo: return "photo"
        case .audio: return "waveform"
        case .sidecar: return "doc.text"
        case .other: return "doc"
        }
    }

    var isMedia: Bool { self == .video || self == .photo || self == .audio }
}

// MARK: - Settings

enum DatePosition: String, Codable, CaseIterable, Identifiable {
    case after, before, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .after: return "Project name + date"
        case .before: return "Date + project name"
        case .none: return "No date"
        }
    }
}

enum CloudMode: String, Codable, CaseIterable, Identifiable {
    case ownAccount, existingRemote
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ownAccount: return "Google account (sign in through BCKUP)"
        case .existingRemote: return "Existing rclone remote"
        }
    }
}

enum CheckMode: String, Codable, CaseIterable, Identifiable {
    case thorough, fast
    var id: String { rawValue }
    var label: String {
        switch self {
        case .thorough: return "Thorough: compare file contents (hash)"
        case .fast: return "Quick: match name, size & date"
        }
    }
    var help: String {
        switch self {
        case .thorough: return "Safest. Files on the card are read and compared by content with what's already at the destination, so moved or renamed files are still recognised."
        case .fast: return "Faster for big cards, but skipped files aren't compared by content, so a card can't be marked \"Safe to format\"."
        }
    }
}

struct AppSettings: Codable, Equatable {
    var primaryRoot: String? = nil
    var backupRoots: [String] = []
    var useClientFolder = false
    var datePosition: DatePosition = .after
    var dateFormat = "dd.MM.yy"
    var separateByType = true
    var videoFolder = "Video"
    var photoFolder = "Photo"
    var audioFolder = "Audio"
    var skipExisting = true
    var checkMode: CheckMode = .thorough
    var cloudEnabled = false
    var cloudMode: CloudMode = .ownAccount
    var cloudClientID = ""
    var cloudClientSecret = ""
    var cloudRemote = ""
    var cloudPath = "Footage"
    var autoOpenOnCard = true
    var hiddenVolumes: [String] = []
    var lastClient = ""
    var lastProject = ""
    var lastUsed: Double = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        primaryRoot = try c.decodeIfPresent(String.self, forKey: .primaryRoot) ?? d.primaryRoot
        backupRoots = try c.decodeIfPresent([String].self, forKey: .backupRoots) ?? d.backupRoots
        useClientFolder = try c.decodeIfPresent(Bool.self, forKey: .useClientFolder) ?? d.useClientFolder
        datePosition = try c.decodeIfPresent(DatePosition.self, forKey: .datePosition) ?? d.datePosition
        dateFormat = try c.decodeIfPresent(String.self, forKey: .dateFormat) ?? d.dateFormat
        separateByType = try c.decodeIfPresent(Bool.self, forKey: .separateByType) ?? d.separateByType
        videoFolder = try c.decodeIfPresent(String.self, forKey: .videoFolder) ?? d.videoFolder
        photoFolder = try c.decodeIfPresent(String.self, forKey: .photoFolder) ?? d.photoFolder
        audioFolder = try c.decodeIfPresent(String.self, forKey: .audioFolder) ?? d.audioFolder
        skipExisting = try c.decodeIfPresent(Bool.self, forKey: .skipExisting) ?? d.skipExisting
        checkMode = try c.decodeIfPresent(CheckMode.self, forKey: .checkMode) ?? d.checkMode
        cloudEnabled = try c.decodeIfPresent(Bool.self, forKey: .cloudEnabled) ?? d.cloudEnabled
        cloudRemote = try c.decodeIfPresent(String.self, forKey: .cloudRemote) ?? d.cloudRemote
        cloudMode = try c.decodeIfPresent(CloudMode.self, forKey: .cloudMode) ?? d.cloudMode
        cloudClientID = try c.decodeIfPresent(String.self, forKey: .cloudClientID) ?? d.cloudClientID
        cloudClientSecret = try c.decodeIfPresent(String.self, forKey: .cloudClientSecret) ?? d.cloudClientSecret
        cloudPath = try c.decodeIfPresent(String.self, forKey: .cloudPath) ?? d.cloudPath
        autoOpenOnCard = try c.decodeIfPresent(Bool.self, forKey: .autoOpenOnCard) ?? d.autoOpenOnCard
        hiddenVolumes = try c.decodeIfPresent([String].self, forKey: .hiddenVolumes) ?? d.hiddenVolumes
        lastClient = try c.decodeIfPresent(String.self, forKey: .lastClient) ?? d.lastClient
        lastProject = try c.decodeIfPresent(String.self, forKey: .lastProject) ?? d.lastProject
        lastUsed = try c.decodeIfPresent(Double.self, forKey: .lastUsed) ?? d.lastUsed
    }

    private static let key = "settings.v1"

    static func load() -> AppSettings {
        let old = UserDefaults(suiteName: "local.amanin.app")?.data(forKey: key)
        guard let data = UserDefaults.standard.data(forKey: key) ?? old,
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: AppSettings.key) }
    }

    /// The rclone remote BCKUP should use, or nil when Google Drive isn't set up on this Mac.
    func cloudSpec() -> CloudSpec? {
        guard let rc = Cloud.findRclone() else { return nil }
        switch cloudMode {
        case .ownAccount:
            return CloudSpec(rclone: rc, remote: Cloud.ownRemote + ":", path: cloudPath, extraArgs: Cloud.ownConfigArgs)
        case .existingRemote:
            return cloudRemote.isEmpty ? nil : CloudSpec(rclone: rc, remote: cloudRemote, path: cloudPath)
        }
    }

    /// Why Google Drive can't be used right now (nil when ready).
    var cloudIssue: String? {
        if Cloud.findRclone() == nil { return "rclone isn't included in this app" }
        switch cloudMode {
        case .ownAccount: return Cloud.ownAccountConnected ? nil : "Google account not connected (Settings → Google Drive)"
        case .existingRemote: return cloudRemote.isEmpty ? "Choose a remote in Settings → Google Drive" : nil
        }
    }

    var cloudDisplay: String {
        let p = cloudPath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        switch cloudMode {
        case .ownAccount: return "Google Drive" + (p.isEmpty ? "" : " › " + p)
        case .existingRemote: return (cloudRemote.isEmpty ? "remote:" : cloudRemote) + p
        }
    }

    var lastProjectRel: String? {
        guard !lastProject.isEmpty else { return nil }
        return useClientFolder && !lastClient.isEmpty ? lastClient + "/" + lastProject : lastProject
    }

    var kindFolders: [FileKind: String] {
        [.video: videoFolder, .photo: photoFolder, .audio: audioFolder]
    }

    func projectFolderName(project: String, date: Date) -> String {
        let name = cleanName(project)
        guard !name.isEmpty else { return "" }
        let d = dateFormatter(dateFormat).string(from: date)
        switch datePosition {
        case .after: return "\(name) \(d)"
        case .before: return "\(d) \(name)"
        case .none: return name
        }
    }
}

// MARK: - Card contents

struct CardFile: Hashable, Identifiable {
    var id: String { rel }
    let url: URL
    let rel: String
    let size: Int64
    let mtime: Date
    let kind: FileKind
}

struct CardScan {
    let root: URL
    let name: String
    let files: [CardFile]
    let camera: String
    let model: String?
    let totalBytes: Int64
    let counts: [FileKind: Int]
    let suggestedDate: Date
    let firstDate: Date?
    let lastDate: Date?
}

// MARK: - Offload spec / plan / result

struct CloudSpec {
    let rclone: String
    let remote: String
    let path: String
    var extraArgs: [String] = []

    var target: String {
        let r = remote.hasSuffix(":") ? remote : remote + ":"
        let p = path.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return p.isEmpty ? r : r + p
    }
}

struct OffloadSpec {
    var source: URL
    var clientFolder: String?
    var projectFolder: String
    var roll: String
    var destinations: [String]   // first = primary
    var separateByType: Bool
    var kindFolders: [FileKind: String]
    var skipExisting: Bool
    var checkMode: CheckMode
    var cloud: CloudSpec?
    /// When set, files keep their own relative path under this folder (used for project-to-backup copies).
    var mirrorPrefix: String? = nil

    var projectRel: String {
        [clientFolder ?? "", projectFolder].filter { !$0.isEmpty }.joined(separator: "/")
    }

    func targetRel(for file: CardFile, routed: FileKind) -> String {
        if let m = mirrorPrefix { return m.isEmpty ? file.rel : m + "/" + file.rel }
        var parts = [projectRel]
        if separateByType, let k = kindFolders[routed], !k.isEmpty { parts.append(k) }
        if !roll.isEmpty { parts.append(roll) }
        parts.append(file.rel)
        return parts.filter { !$0.isEmpty }.joined(separator: "/")
    }
}

enum DestAction: Hashable {
    case skip(existing: String, verified: Bool)
    case copy(target: String, renamed: Bool)
}

struct PlanItem: Identifiable {
    var id: String { file.rel }
    let file: CardFile
    let routed: FileKind
    let actions: [String: DestAction]
    let cardHash: String?

    var needsCopy: Bool {
        actions.values.contains { if case .copy = $0 { return true } else { return false } }
    }
    var isRenamed: Bool {
        actions.values.contains { if case .copy(_, true) = $0 { return true } else { return false } }
    }
}

struct DestSummary {
    let root: String
    var skip = 0
    var copy = 0
    var bytes: Int64 = 0
    var renamed = 0
    var free: Int64?

    var spaceProblem: Bool {
        guard let free else { return false }
        return bytes > free
    }
}

struct OffloadPlan {
    let spec: OffloadSpec
    let scan: CardScan
    let items: [PlanItem]
    let summaries: [DestSummary]

    var filesToCopy: Int { items.filter(\.needsCopy).count }
    var bytesToCopy: Int64 { items.filter(\.needsCopy).reduce(0) { $0 + $1.file.size } }
    var renamedCount: Int { items.filter(\.isRenamed).count }
    var hasSpaceProblem: Bool { summaries.contains(where: \.spaceProblem) }
}

enum DestOutcome {
    case existing(rel: String, verified: Bool)
    case copied(rel: String)
    case failed(String)

    var isSafe: Bool {
        switch self {
        case .copied: return true
        case .existing(_, let v): return v
        case .failed: return false
        }
    }
    var isPresent: Bool {
        if case .failed = self { return false }
        return true
    }
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
    var label: String {
        switch self {
        case .copied: return "Copied & verified"
        case .existing(_, true): return "Already there (contents match)"
        case .existing(_, false): return "Already there (quick check)"
        case .failed(let m): return "Failed: \(m)"
        }
    }
    var rel: String? {
        switch self {
        case .copied(let r), .existing(let r, _): return r
        case .failed: return nil
        }
    }
}

struct ItemResult: Identifiable {
    var id: String { file.rel }
    let file: CardFile
    let hash: String?
    let outcomes: [String: DestOutcome]
}

enum Verdict {
    case safe(Int), oneCopy, unverified, failed(Int), cancelled, empty

    var title: String {
        switch self {
        case .safe: return "Safe to format"
        case .oneCopy: return "Only 1 copy"
        case .unverified: return "Probably safe"
        case .failed(let n): return "\(n) files failed"
        case .cancelled: return "Cancelled"
        case .empty: return "Empty card"
        }
    }

    var detail: String {
        switch self {
        case .safe(let n): return "Every file is in \(n) places and its contents were checked. You can format the card."
        case .oneCopy: return "Every file is safe in one place, but there's no second copy yet. Don't format the card until there's a backup."
        case .unverified: return "Some files were counted as already there by a quick check, without comparing contents. Check again in Thorough mode before formatting."
        case .failed: return "Don't format the card. See the failed files below, then try again."
        case .cancelled: return "The copy stopped. Files that didn't finish were not saved under their real names."
        case .empty: return "There are no files on this card."
        }
    }

    var isGood: Bool { if case .safe = self { return true }; return false }
}

struct OffloadResult {
    let spec: OffloadSpec
    var items: [ItemResult]
    var cancelled: Bool
    var cloudOK: Bool? = nil
    var cloudMessage: String? = nil
    var reports: [String] = []
    var startedAt: Date? = nil
    var finishedAt: Date? = nil

    var failures: Int { items.filter { $0.outcomes.values.contains(where: \.isFailure) }.count }
    var copiedCount: Int {
        items.filter { $0.outcomes.values.contains { if case .copied = $0 { return true } else { return false } } }.count
    }
    var existingOnlyCount: Int {
        items.filter { item in
            !item.outcomes.isEmpty && item.outcomes.values.allSatisfy { if case .existing = $0 { return true } else { return false } }
        }.count
    }
    var copiedBytes: Int64 {
        items.filter { $0.outcomes.values.contains { if case .copied = $0 { return true } else { return false } } }
            .reduce(0) { $0 + $1.file.size }
    }

    var verdict: Verdict {
        if items.isEmpty { return .empty }
        if cancelled { return .cancelled }
        let f = failures
        if f > 0 { return .failed(f) }
        let cloud = cloudOK == true ? 1 : 0
        let minPresent = items.map { $0.outcomes.values.filter(\.isPresent).count + cloud }.min() ?? 0
        let minSafe = items.map { $0.outcomes.values.filter(\.isSafe).count + cloud }.min() ?? 0
        if minSafe >= 2 { return .safe(minSafe) }
        if minPresent >= 2 { return .unverified }
        return .oneCopy
    }
}

struct EngineProgress {
    var phase: String = ""
    var detail: String = ""
    var done: Int64 = 0
    var total: Int64 = 0
    var isBytes = true
    var fileIndex = 0
    var fileCount = 0
    var fileName = ""

    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
}
