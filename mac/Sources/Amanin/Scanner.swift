import Foundation
import ImageIO

// MARK: - Media types (broad: cinema, mirrorless, drone, action cam, phone, audio recorders)

enum MediaTypes {
    static let video: Set<String> = [
        "mp4", "mov", "mxf", "braw", "r3d", "ari", "arx", "mts", "m2ts", "m2t", "avi", "crm", "insv",
        "mkv", "m4v", "mpg", "mpeg", "3gp", "wmv", "cine", "nev", "vrw", "dv", "hevc", "h264", "h265",
        "webm", "mod", "tod", "vob", "lrv360", "360", "ts"
    ]
    static let photo: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "hif", "png", "tif", "tiff", "dng", "arw", "srf", "sr2", "cr2", "cr3",
        "crw", "nef", "nrw", "raf", "rw2", "rwl", "orf", "ori", "pef", "srw", "x3f", "gpr", "3fr", "fff",
        "iiq", "erf", "kdc", "mef", "mos", "raw", "insp", "jxl", "avif", "webp", "bmp", "psd", "dcr", "mrw"
    ]
    static let audio: Set<String> = [
        "wav", "bwf", "mp3", "m4a", "aac", "aif", "aiff", "flac", "ogg", "wma", "rf64", "w64", "caf"
    ]
    static let sidecar: Set<String> = [
        "xml", "xmp", "thm", "lrv", "lrf", "srt", "bim", "cpi", "mpl", "bdm", "smi", "ppn", "sav", "rdc",
        "rmd", "rtn", "ale", "cdl", "cube", "mhl", "txt", "log", "csv", "json", "dat", "cfg", "ind", "idx",
        "mif", "bin", "glv", "obs", "sidecar", "gyro", "dji", "xmpx", "ipl", "mhd"
    ]

    static func kind(ofExtension e: String) -> FileKind {
        let e = e.lowercased()
        if video.contains(e) { return .video }
        if photo.contains(e) { return .photo }
        if audio.contains(e) { return .audio }
        if sidecar.contains(e) { return .sidecar }
        return .other
    }
}

// MARK: - Card scanner

enum CardScanner {
    static let skipNames: Set<String> = [
        ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DocumentRevisions-V100",
        "System Volume Information", "$RECYCLE.BIN", "_BCKUP Reports", "_Laporan BCKUP", "_Laporan Amanin"
    ]

    static let cardRoots: Set<String> = [
        "DCIM", "PRIVATE", "CONTENTS", "XDROOT", "AVCHD", "CLIPS001", "M4ROOT", "DJI", "CAMERA01", "NIKON",
        "MISC", "AVF_INFO", "BLACKMAGIC", "FOLDER01", "ZOOM", "TASCAM", "MP_ROOT", "HDV", "SONY", "BPAV",
        "CLIP", "STREAM", "PANA_GRP", "INSTA360", "GOPRO", "EOS_DIGITAL", "CANONMSC", "MP_ROOT", "AVCHDTN"
    ]

    static let topLevelMediaHints: Set<String> = ["braw", "r3d", "rdm", "rdc", "mxf", "ari", "arx", "wav", "crm", "insv", "mov", "mp4"]

    /// Cheap check of the top level of a volume: does it look like a camera / recorder card?
    static func looksLikeCard(_ url: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return false }
        let upper = Set(names.map { $0.uppercased() })
        let systemish: Set<String> = ["LIBRARY", "USERS", "APPLICATIONS", "SYSTEM", "BACKUPS.BACKUPDB", "CONTENTS.PLIST"]
        if !upper.isDisjoint(with: systemish) { return false }
        if !upper.isDisjoint(with: cardRoots) { return true }
        var mediaCount = 0
        for n in names where !n.hasPrefix(".") {
            let e = (n as NSString).pathExtension.lowercased()
            if topLevelMediaHints.contains(e) { mediaCount += 1 }
        }
        return mediaCount > 0 && names.count < 2000
    }

    static func scan(_ root: URL, cancel: CancelFlag? = nil) throws -> CardScan {
        let rootPath = root.standardizedFileURL.path
        var files: [CardFile] = []
        try collect(dir: root, rootPath: rootPath, into: &files, cancel: cancel)
        let volName = (try? root.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? nil
        let isVolumeRoot = (try? root.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
        return finish(root: root, name: (isVolumeRoot ? volName : nil) ?? root.lastPathComponent, files: files)
    }

    /// Scan a loose set of dropped files and folders. Paths are kept relative to their common parent folder.
    static func scan(items: [URL], name: String, cancel: CancelFlag? = nil) throws -> CardScan {
        let parents = items.map { $0.standardizedFileURL.deletingLastPathComponent().pathComponents }
        var common = parents.first ?? ["/"]
        for p in parents.dropFirst() {
            var i = 0
            while i < common.count && i < p.count && common[i] == p[i] { i += 1 }
            common = Array(common.prefix(i))
        }
        let root = URL(fileURLWithPath: NSString.path(withComponents: common.isEmpty ? ["/"] : common))
        let rootPath = root.standardizedFileURL.path
        var files: [CardFile] = []
        for u in items {
            if cancel?.isCancelled == true { throw AppError.cancelled }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                try collect(dir: u, rootPath: rootPath, into: &files, cancel: cancel)
            } else if let f = cardFile(u, rootPath: rootPath) {
                files.append(f)
            }
        }
        var seen = Set<String>()
        files = files.filter { seen.insert($0.rel).inserted }
        return finish(root: root, name: name, files: files, camera: "Dropped files")
    }

    private static let fileKeys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]

    private static func cardFile(_ u: URL, rootPath: String) -> CardFile? {
        let name = u.lastPathComponent
        if name.hasPrefix(".") || name.hasSuffix(".amanin-part") { return nil }
        guard let rv = try? u.resourceValues(forKeys: Set(fileKeys)), rv.isRegularFile == true else { return nil }
        return CardFile(
            url: u,
            rel: relPath(u, root: rootPath),
            size: Int64(rv.fileSize ?? 0),
            mtime: rv.contentModificationDate ?? Date(timeIntervalSince1970: 0),
            kind: MediaTypes.kind(ofExtension: u.pathExtension)
        )
    }

    private static func collect(dir: URL, rootPath: String, into files: inout [CardFile], cancel: CancelFlag?) throws {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: fileKeys, options: [.skipsHiddenFiles]) else {
            throw AppError.io("Couldn't read \(dir.path)")
        }
        for case let u as URL in en {
            if cancel?.isCancelled == true { throw AppError.cancelled }
            if skipNames.contains(u.lastPathComponent) { en.skipDescendants(); continue }
            if let f = cardFile(u, rootPath: rootPath) { files.append(f) }
        }
    }

    private static func finish(root: URL, name: String, files unsorted: [CardFile], camera: String? = nil) -> CardScan {
        var files = unsorted
        files.sort { $0.rel.localizedStandardCompare($1.rel) == .orderedAscending }

        var counts: [FileKind: Int] = [:]
        for f in files { counts[f.kind, default: 0] += 1 }
        let media = files.filter { $0.kind.isMedia }
        let dates = media.map(\.mtime).filter { $0.timeIntervalSince1970 > 0 }

        let dayFmt = dateFormatter("yyyy-MM-dd")
        var perDay: [String: (count: Int, date: Date)] = [:]
        for d in dates {
            let k = dayFmt.string(from: d)
            let cur = perDay[k]
            perDay[k] = ((cur?.count ?? 0) + 1, cur?.date ?? d)
        }
        let suggested = perDay.values.max { $0.count < $1.count }?.date ?? Date()

        return CardScan(
            root: root,
            name: name,
            files: files,
            camera: camera ?? CameraDetector.detect(files),
            model: CameraDetector.model(files),
            totalBytes: files.reduce(0) { $0 + $1.size },
            counts: counts,
            suggestedDate: suggested,
            firstDate: dates.min(),
            lastDate: dates.max()
        )
    }
}

// MARK: - Camera detection

enum CameraDetector {
    static func detect(_ files: [CardFile]) -> String {
        if files.isEmpty { return "Empty card" }
        let rels = files.map { $0.rel.uppercased() }
        var exts: [String: Int] = [:]
        for f in files { exts[f.url.pathExtension.lowercased(), default: 0] += 1 }
        func has(_ e: String...) -> Bool { e.contains { exts[$0] != nil } }
        func path(_ s: String) -> Bool { rels.contains { $0.contains(s) } }
        func name(prefix: String) -> Bool { files.contains { $0.url.lastPathComponent.uppercased().hasPrefix(prefix) } }

        if path("M4ROOT/") { return "Sony (XAVC)" }
        if path("XDROOT/") || path("BPAV/") { return "Sony XDCAM" }
        if has("crm") { return "Canon Cinema RAW Light" }
        if path("CONTENTS/CLIPS") { return "Canon Cinema EOS" }
        if has("braw") { return "Blackmagic (BRAW)" }
        if has("r3d") { return "RED" }
        if has("ari", "arx") { return "ARRI" }
        if has("insv", "insp") || path("INSTA360") { return "Insta360" }
        if name(prefix: "DJI_") || path("/DJI") || path("DJI_") || has("lrf") { return "DJI" }
        if path("GOPRO") || has("gpr") || name(prefix: "GOPR") || name(prefix: "GX0") || name(prefix: "GH0") { return "GoPro" }
        if path("PANA_GRP") || path("_PANA") || has("rw2") { return "Panasonic" }
        if has("arw", "srf", "sr2") || path("MSDCF") { return "Sony" }
        if has("cr2", "cr3", "crw") || path("CANON") || path("EOSMISC") { return "Canon" }
        if has("nef", "nrw", "nev") || path("NIKON") || path("NCFL") { return "Nikon" }
        if has("raf") || path("_FUJI") { return "Fujifilm" }
        if has("orf", "ori") || path("OLYMP") || path("OMSYS") { return "OM System / Olympus" }
        if has("pef") || path("PENTX") { return "Pentax / Ricoh" }
        if has("3fr", "fff") { return "Hasselblad" }
        if has("x3f") || path("SIGMA") { return "Sigma" }
        if path("LEICA") || has("rwl") { return "Leica" }
        if has("iiq") { return "Phase One" }
        if path("AVCHD") { return "AVCHD camera" }
        if name(prefix: "ZOOM") || path("ZOOM") { return "Zoom (audio recorder)" }
        if path("TASCAM") || name(prefix: "TASCAM") { return "Tascam (audio recorder)" }
        if has("mxf") { return "Broadcast camera (MXF)" }

        var v = 0, p = 0, a = 0
        for f in files {
            switch f.kind {
            case .video: v += 1
            case .photo: p += 1
            case .audio: a += 1
            default: break
            }
        }
        if a > v && a > p { return "Audio recorder" }
        if v >= p && v > 0 { return "Video camera" }
        if p > 0 { return "Photo camera" }
        return "Unknown"
    }

    /// Reads Make/Model from the EXIF of the first readable photo on the card.
    static func model(_ files: [CardFile]) -> String? {
        let exts: Set<String> = ["jpg", "jpeg", "arw", "cr3", "cr2", "nef", "raf", "rw2", "orf", "dng", "heic", "hif", "pef", "srw", "gpr", "insp"]
        let photos = files.filter { exts.contains($0.url.pathExtension.lowercased()) }.prefix(4)
        for f in photos {
            guard let src = CGImageSourceCreateWithURL(f.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] else { continue }
            let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let model, !model.isEmpty else { continue }
            if let make, !make.isEmpty,
               let first = make.split(separator: " ").first,
               !model.lowercased().hasPrefix(first.lowercased()) {
                return "\(make) \(model)"
            }
            return model
        }
        return nil
    }
}

// MARK: - Routing files into Video / Photo / Audio

enum Router {
    /// Folders that belong to a video camera's clip structure; everything under them stays together.
    static let videoStructure: Set<String> = ["M4ROOT", "XDROOT", "CONTENTS", "AVCHD", "BDMV", "PANA_GRP", "CLIPS001", "XAVC", "BPAV"]

    static func route(_ files: [CardFile]) -> [String: FileKind] {
        var out: [String: FileKind] = [:]
        var byDir: [String: [CardFile]] = [:]
        for f in files { byDir[(f.rel as NSString).deletingLastPathComponent, default: []].append(f) }
        let cardMajority = majority(files) ?? .video

        for f in files {
            let comps = f.rel.uppercased().split(separator: "/").map(String.init).dropLast()
            if comps.contains(where: { videoStructure.contains($0) || $0.hasSuffix(".RDC") || $0.hasSuffix(".RDM") }) {
                out[f.rel] = .video
                continue
            }
            if f.kind.isMedia {
                out[f.rel] = f.kind
                continue
            }
            let dir = (f.rel as NSString).deletingLastPathComponent
            let siblings = byDir[dir] ?? []
            let stem = (f.url.lastPathComponent as NSString).deletingPathExtension.uppercased()
            let partner = siblings.first { s in
                guard s.kind.isMedia else { return false }
                let ss = (s.url.lastPathComponent as NSString).deletingPathExtension.uppercased()
                return !ss.isEmpty && !stem.isEmpty && (stem.hasPrefix(ss) || ss.hasPrefix(stem))
            }
            out[f.rel] = partner?.kind ?? majority(siblings) ?? cardMajority
        }
        return out
    }

    static func majority(_ files: [CardFile]) -> FileKind? {
        var c: [FileKind: Int] = [:]
        for f in files where f.kind.isMedia { c[f.kind, default: 0] += 1 }
        return c.max { $0.value < $1.value }?.key
    }
}
