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

    /// The card's camera: EXIF of the first photo, else the metadata of the first clip.
    static func model(_ files: [CardFile]) -> String? {
        if let m = photoModel(files) { return m }
        for f in files.filter({ $0.kind == .video }).prefix(3) {
            if let d = DeviceDetector.device(for: f.url) { return d }
        }
        return nil
    }

    /// Reads Make/Model from the EXIF of the first readable photo on the card.
    static func photoModel(_ files: [CardFile]) -> String? {
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


// MARK: - Device detection (which camera or phone made a file)

enum DeviceDetector {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    nonisolated(unsafe) private static var misses = Set<String>()

    /// A readable device name such as "iPhone 15 Pro", "Sony ILCE-7M4", "Pixel 8" or "DJI", or nil if unknown.
    static func device(for url: URL) -> String? {
        let key = url.path
        lock.lock()
        if let d = cache[key] { lock.unlock(); return d }
        if misses.contains(key) { lock.unlock(); return nil }
        lock.unlock()
        let d = detect(url)
        lock.lock()
        if let d { cache[key] = d } else { misses.insert(key) }
        lock.unlock()
        return d
    }

    private static func detect(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let kind = MediaTypes.kind(ofExtension: ext)
        if kind == .photo, let (make, model) = exif(url) { return pretty(make: make, model: model) }
        if kind == .video {
            if let (make, model) = sonyXML(url) { return pretty(make: make, model: model) }
            if let (make, model) = videoMetadata(url) { return pretty(make: make, model: model) }
        }
        return fromName(url)
    }

    static func exif(_ url: URL) -> (String?, String)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
              let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty
        else { return nil }
        return ((tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), model)
    }

    /// Sony writes <Device manufacturer="Sony" modelName="ILCE-7M4"/> into C0001M01.XML next to each clip.
    static func sonyXML(_ url: URL) -> (String?, String)? {
        let stem = url.deletingPathExtension().lastPathComponent
        for name in ["\(stem)M01.XML", "\(stem)M01.xml"] {
            let x = url.deletingLastPathComponent().appendingPathComponent(name)
            guard let text = try? String(contentsOf: x, encoding: .utf8) else { continue }
            func attr(_ a: String) -> String? {
                guard let r = text.range(of: a + "=\""), let e = text[r.upperBound...].firstIndex(of: "\"") else { return nil }
                return String(text[r.upperBound..<e])
            }
            if let model = attr("modelName"), !model.isEmpty { return (attr("manufacturer"), model) }
        }
        return nil
    }

    /// QuickTime / MP4 metadata: Apple (com.apple.quicktime.make/model), Android (com.android.manufacturer/model)
    /// and the classic ©mak / ©mod atoms many cameras write.
    static func videoMetadata(_ url: URL) -> (String?, String)? {
        let tags = MP4Tags.read(url)
        func find(_ test: (String) -> Bool) -> String? {
            tags.first { test($0.key.lowercased()) }.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let model = find { ($0.contains("model") && !$0.contains("modelname")) || $0 == "©mod" }
        let make = find { $0.contains("make") || $0.contains("manufacturer") || $0 == "©mak" }
        if let model { return (make, model) }
        if let make { return (nil, make) }
        return nil
    }

    /// Last resort: names cameras and phones give their files.
    static func fromName(_ url: URL) -> String? {
        let n = url.lastPathComponent.uppercased()
        if n.hasPrefix("DJI_") { return "DJI" }
        if n.hasPrefix("GX0") || n.hasPrefix("GH0") || n.hasPrefix("GOPR") || n.hasPrefix("GL0") { return "GoPro" }
        if n.hasPrefix("PXL_") { return "Pixel" }
        if n.hasPrefix("INSTA360") || n.hasSuffix(".INSV") || n.hasSuffix(".INSP") { return "Insta360" }
        return nil
    }

    static func pretty(make: String?, model: String) -> String {
        var m = model
        var mk = (make ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = mk.lowercased()
        if lower.hasPrefix("sony") { mk = "Sony" }
        else if lower.hasPrefix("canon") { mk = "Canon" }
        else if lower.hasPrefix("nikon") { mk = "Nikon" }
        else if lower.hasPrefix("fujifilm") { mk = "Fujifilm" }
        else if lower.hasPrefix("panasonic") { mk = "Panasonic" }
        else if lower.hasPrefix("olympus") || lower.hasPrefix("om digital") { mk = "OM System" }
        else if lower == "apple" || lower == "google" || lower.hasPrefix("samsung") || lower.isEmpty { mk = "" }
        if !mk.isEmpty, let first = mk.split(separator: " ").first, m.lowercased().hasPrefix(first.lowercased()) { mk = "" }
        if m.lowercased().hasPrefix("sm-") { m = "Samsung " + m }
        return mk.isEmpty ? m : "\(mk) \(m)"
    }
}


/// Minimal reader for the metadata in MP4 / MOV files (moov › udta / meta › keys + ilst, and ©xxx atoms).
enum MP4Tags {
    static func read(_ url: URL) -> [String: String] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? fh.close() }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        var off: UInt64 = 0
        while off + 8 <= fileSize {
            try? fh.seek(toOffset: off)
            guard let hdr = try? fh.read(upToCount: 16), hdr.count >= 8 else { break }
            let h = [UInt8](hdr)
            var size = UInt64(be32(h, 0))
            let type = fourCC(h, 4)
            var headerLen: UInt64 = 8
            if size == 1, h.count >= 16 { size = be64(h, 8); headerLen = 16 } else if size == 0 { size = fileSize - off }
            if size < headerLen { break }
            if type == "moov" {
                try? fh.seek(toOffset: off + headerLen)
                let len = Int(min(size - headerLen, 64 << 20))
                guard let data = try? fh.read(upToCount: len) else { return [:] }
                var keys: [String] = []
                var out: [String: String] = [:]
                walk([UInt8](data), 0, data.count, &keys, &out)
                return out
            }
            off += size
        }
        return [:]
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
    private static func be64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(be32(b, i)) << 32 | UInt64(be32(b, i + 4)) }
    private static func fourCC(_ b: [UInt8], _ i: Int) -> String {
        guard i + 4 <= b.count else { return "" }
        return String(bytes: b[i..<i + 4], encoding: .isoLatin1) ?? ""
    }
    private static func text(_ b: [UInt8], _ from: Int, _ to: Int) -> String {
        guard from < to, to <= b.count else { return "" }
        let bytes = Array(b[from..<to]).filter { $0 != 0 }
        return String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    private static let containers: Set<String> = ["moov", "udta", "meta", "ilst", "trak"]

    private static func walk(_ b: [UInt8], _ start: Int, _ end: Int, _ keys: inout [String], _ out: inout [String: String]) {
        var i = start
        while i + 8 <= end {
            let size = Int(be32(b, i))
            let type = fourCC(b, i + 4)
            guard size >= 8, i + size <= end else { break }
            let body = i + 8
            let stop = i + size
            switch type {
            case "meta":
                // ISO 'meta' has 4 bytes of version/flags before its children; QuickTime's doesn't.
                let skip = be32(b, body) == 0 ? 4 : 0
                walk(b, body + skip, stop, &keys, &out)
            case "keys":
                var j = body + 8
                let count = Int(be32(b, body + 4))
                for _ in 0..<count where j + 8 <= stop {
                    let ks = Int(be32(b, j))
                    guard ks >= 8 else { break }
                    keys.append(text(b, j + 8, min(j + ks, stop)))
                    j += ks
                }
            case "ilst":
                var j = body
                while j + 8 <= stop {
                    let isz = Int(be32(b, j))
                    guard isz >= 8, j + isz <= stop else { break }
                    let idx = Int(be32(b, j + 4))
                    let name = (idx > 0 && idx <= keys.count) ? keys[idx - 1] : fourCC(b, j + 4)
                    if let v = dataValue(b, j + 8, j + isz) { out[name] = v }
                    j += isz
                }
            default:
                if containers.contains(type) {
                    walk(b, body, stop, &keys, &out)
                } else if b[i + 4] == 0xA9 {
                    // QuickTime text atom: either a 'data' child, or [length 2][language 2][text].
                    let name = "©" + (String(bytes: b[(i + 5)..<(i + 8)], encoding: .isoLatin1) ?? "")
                    if let v = dataValue(b, body, stop) { out[name] = v }
                    else if body + 4 <= stop {
                        let len = Int(b[body]) << 8 | Int(b[body + 1])
                        out[name] = text(b, body + 4, min(body + 4 + len, stop))
                    }
                }
            }
            i = stop
        }
    }

    private static func dataValue(_ b: [UInt8], _ start: Int, _ end: Int) -> String? {
        var j = start
        while j + 16 <= end {
            let s = Int(be32(b, j))
            guard s >= 8, j + s <= end else { return nil }
            if fourCC(b, j + 4) == "data" { return text(b, j + 16, j + s) }
            j += s
        }
        return nil
    }
}
