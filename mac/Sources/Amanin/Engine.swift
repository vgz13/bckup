import Foundation

// MARK: - Offload engine (plan → copy & verify → optional cloud)

final class OffloadEngine: @unchecked Sendable {
    let catalog: Catalog
    let cancel: CancelFlag

    init(catalog: Catalog, cancel: CancelFlag) {
        self.catalog = catalog
        self.cancel = cancel
    }

    // MARK: Plan

    func plan(spec: OffloadSpec, scan: CardScan, progress: (EngineProgress) -> Void) throws -> OffloadPlan {
        let routed = Router.route(scan.files)
        var actions: [String: [String: DestAction]] = [:]
        var cardHashes: [String: String] = [:]
        let fm = FileManager.default
        let totalSteps = Int64(scan.files.count * max(1, spec.destinations.count))
        var step: Int64 = 0

        for root in spec.destinations {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else { throw AppError.notConnected(root) }

            let vol = volumeName(forPath: root)
            progress(EngineProgress(phase: "Reading \(vol)", detail: root, done: 0, total: 0, isBytes: false))
            try catalog.refresh(root: root, cancel: cancel) { n in
                progress(EngineProgress(phase: "Reading \(vol)", detail: "\(n) files found", done: 0, total: 0, isBytes: false))
            }

            var planned = Set<String>()
            for f in scan.files {
                if cancel.isCancelled { throw AppError.cancelled }
                step += 1
                var action: DestAction?

                if spec.skipExisting {
                    let cands = catalog.candidates(root: root, size: f.size)
                    if !cands.isEmpty {
                        let fname = f.url.lastPathComponent
                        func sameName(_ e: Catalog.Entry) -> Bool {
                            (e.rel as NSString).lastPathComponent.caseInsensitiveCompare(fname) == .orderedSame
                        }
                        switch spec.checkMode {
                        case .fast:
                            if let c = cands.first(where: { sameName($0) && abs($0.mtime - f.mtime.timeIntervalSince1970) < 2.5 }) {
                                action = .skip(existing: c.rel, verified: false)
                            }
                        case .thorough:
                            progress(EngineProgress(phase: "Comparing with \(vol)", detail: f.rel, done: step, total: totalSteps, isBytes: false))
                            let cardHash: String
                            if let h = cardHashes[f.rel] {
                                cardHash = h
                            } else {
                                cardHash = try IO.hashFile(f.url.path, cancel: cancel)
                                cardHashes[f.rel] = cardHash
                            }
                            let ordered = cands.sorted { sameName($0) && !sameName($1) }
                            for c in ordered {
                                var h = c.hash
                                if h == nil {
                                    let p = root + "/" + c.rel
                                    guard fm.fileExists(atPath: p) else { continue }
                                    do {
                                        let computed = try IO.hashFile(p, cancel: cancel)
                                        catalog.setHash(root: root, rel: c.rel, hash: computed)
                                        h = computed
                                    } catch AppError.cancelled {
                                        throw AppError.cancelled
                                    } catch {
                                        continue
                                    }
                                }
                                if h == cardHash {
                                    action = .skip(existing: c.rel, verified: true)
                                    break
                                }
                            }
                        }
                    }
                }

                if action == nil {
                    var renamed = false
                    let target = uniqueTarget(root: root, rel: spec.targetRel(for: f, routed: routed[f.rel] ?? .video), planned: &planned, renamed: &renamed)
                    action = .copy(target: target, renamed: renamed)
                }
                actions[f.rel, default: [:]][root] = action
                if step % 50 == 0 {
                    progress(EngineProgress(phase: "Checking \(vol)", detail: f.rel, done: step, total: totalSteps, isBytes: false))
                }
            }
        }

        let items = scan.files.map {
            PlanItem(file: $0, routed: routed[$0.rel] ?? .video, actions: actions[$0.rel] ?? [:], cardHash: cardHashes[$0.rel])
        }
        var summaries = spec.destinations.map { DestSummary(root: $0, free: freeSpace(atPath: $0)) }
        for item in items {
            for (i, root) in spec.destinations.enumerated() {
                switch item.actions[root] {
                case .skip?:
                    summaries[i].skip += 1
                case .copy(_, let renamed)?:
                    summaries[i].copy += 1
                    summaries[i].bytes += item.file.size
                    if renamed { summaries[i].renamed += 1 }
                case nil:
                    break
                }
            }
        }
        return OffloadPlan(spec: spec, scan: scan, items: items, summaries: summaries)
    }

    private func uniqueTarget(root: String, rel: String, planned: inout Set<String>, renamed: inout Bool) -> String {
        let fm = FileManager.default
        func taken(_ r: String) -> Bool { planned.contains(r.lowercased()) || fm.fileExists(atPath: root + "/" + r) }
        var candidate = rel
        if taken(candidate) {
            renamed = true
            let dir = (rel as NSString).deletingLastPathComponent
            let name = (rel as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var n = 2
            repeat {
                let newName = ext.isEmpty ? "\(stem)_\(n)" : "\(stem)_\(n).\(ext)"
                candidate = dir.isEmpty ? newName : dir + "/" + newName
                n += 1
            } while taken(candidate)
        }
        planned.insert(candidate.lowercased())
        return candidate
    }

    // MARK: Execute

    func execute(plan: OffloadPlan, progress: (EngineProgress) -> Void) -> OffloadResult {
        let spec = plan.spec
        var total: Int64 = 0
        for item in plan.items {
            let n = Int64(item.actions.values.filter { if case .copy = $0 { return true } else { return false } }.count)
            if n > 0 { total += item.file.size * (1 + n) }
        }
        var done: Int64 = 0
        var results: [ItemResult] = []
        var cancelled = false
        let copyCount = plan.filesToCopy
        var copyIndex = 0

        for item in plan.items {
            var outcomes: [String: DestOutcome] = [:]
            var hash = item.cardHash
            var targets: [(root: String, rel: String)] = []
            for root in spec.destinations {
                switch item.actions[root] {
                case .skip(let existing, let verified)?:
                    outcomes[root] = .existing(rel: existing, verified: verified)
                case .copy(let t, _)?:
                    targets.append((root, t))
                case nil:
                    break
                }
            }

            if !targets.isEmpty {
                if cancelled || cancel.isCancelled {
                    cancelled = true
                    for t in targets { outcomes[t.root] = .failed("Cancelled") }
                } else {
                    copyIndex += 1
                    let label = "File \(copyIndex) of \(copyCount): \(item.file.url.lastPathComponent)"
                    // Card file must be the one we scanned.
                    let rv = try? item.file.url.resourceValues(forKeys: [.fileSizeKey])
                    if let s = rv?.fileSize, Int64(s) != item.file.size {
                        for t in targets { outcomes[t.root] = .failed("The file on the card changed since it was checked") }
                    } else {
                        let urls = targets.map { URL(fileURLWithPath: $0.root).appendingPathComponent($0.rel) }
                        do {
                            let r = try Copier.copy(src: item.file.url, targets: urls, mtime: item.file.mtime, cancel: cancel) { n, phase in
                                done += n
                                progress(EngineProgress(phase: phase, detail: label, done: done, total: total, isBytes: true,
                                                        fileIndex: copyIndex, fileCount: copyCount, fileName: item.file.rel))
                            }
                            if let expected = item.cardHash, expected != r.hash {
                                for (i, t) in targets.enumerated() {
                                    if let f = r.finals[i] { try? FileManager.default.removeItem(at: f) }
                                    outcomes[t.root] = .failed("The file's contents on the card changed since it was checked")
                                }
                            } else {
                                hash = r.hash
                                for (i, t) in targets.enumerated() {
                                    if let err = r.errors[i] {
                                        outcomes[t.root] = .failed(err)
                                    } else if let final = r.finals[i] {
                                        let rel = relPath(final, root: URL(fileURLWithPath: t.root).standardizedFileURL.path)
                                        outcomes[t.root] = .copied(rel: rel)
                                        catalog.upsert(root: t.root, entry: .init(rel: rel, size: item.file.size, mtime: item.file.mtime.timeIntervalSince1970, hash: r.hash))
                                    }
                                }
                            }
                        } catch AppError.cancelled {
                            cancelled = true
                            for t in targets { outcomes[t.root] = .failed("Cancelled") }
                        } catch {
                            for t in targets { outcomes[t.root] = .failed(error.localizedDescription) }
                        }
                    }
                }
            }
            results.append(ItemResult(file: item.file, hash: hash, outcomes: outcomes))
        }
        return OffloadResult(spec: spec, items: results, cancelled: cancelled)
    }

    // MARK: Cloud (rclone)

    func upload(result: inout OffloadResult, progress: @escaping (EngineProgress) -> Void) {
        guard let cloud = result.spec.cloud, let primary = result.spec.destinations.first else { return }
        let rels = result.items.compactMap { $0.outcomes[primary]?.rel }
        guard !rels.isEmpty else { return }

        let list = FileManager.default.temporaryDirectory.appendingPathComponent("amanin-files-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: list) }
        do {
            try rels.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        } catch {
            result.cloudOK = false
            result.cloudMessage = "Couldn't make the file list for Google Drive."
            return
        }

        progress(EngineProgress(phase: "Uploading to \(cloud.target)", detail: "Menyiapkan rclone…", done: 0, total: 100, isBytes: false))
        let copyArgs = ["copy", primary, cloud.target, "--files-from", list.path, "--transfers", "4",
                        "--stats", "1s", "--stats-one-line", "--stats-log-level", "NOTICE", "--log-level", "NOTICE"]
        let up = Cloud.run(cloud.rclone, cloud.extraArgs + copyArgs, cancel: cancel) { line in
            if let pct = Cloud.percent(in: line) {
                progress(EngineProgress(phase: "Uploading to \(cloud.target)", detail: Cloud.cleanStats(line), done: Int64(pct), total: 100, isBytes: false))
            }
        }
        if cancel.isCancelled {
            result.cloudOK = false
            result.cloudMessage = "Upload to Google Drive cancelled."
            return
        }
        guard up.status == 0 else {
            result.cloudOK = false
            result.cloudMessage = "Upload to Google Drive failed: \(up.tail.last ?? "rclone keluar dengan kode \(up.status)")"
            return
        }

        progress(EngineProgress(phase: "Checking MD5 on Google Drive", detail: "\(rels.count) files", done: 0, total: 0, isBytes: false))
        let check = Cloud.run(cloud.rclone, cloud.extraArgs + ["check", primary, cloud.target, "--files-from", list.path, "--one-way", "--log-level", "NOTICE"], cancel: cancel) { _ in }
        if check.status == 0 {
            result.cloudOK = true
            result.cloudMessage = "\(rels.count) files are on Google Drive and their MD5s match."
        } else {
            result.cloudOK = false
            result.cloudMessage = "Google Drive check didn't match: \(check.tail.last ?? "kode \(check.status)")"
        }
    }
}

// MARK: - Copier: one read of the card, written to every destination, then read back and compared

enum Copier {
    struct Outcome {
        let hash: String
        let finals: [URL?]
        let errors: [String?]
    }

    static func copy(src: URL, targets: [URL], mtime: Date, cancel: CancelFlag, progress: (Int64, String) -> Void) throws -> Outcome {
        let fm = FileManager.default
        let inFD = Darwin.open(src.path, O_RDONLY)
        guard inFD >= 0 else { throw AppError.io("Couldn't read \(src.lastPathComponent) from the card: \(errnoText())") }
        defer { Darwin.close(inFD) }
        _ = fcntl(inFD, F_NOCACHE, 1)

        var errors = [String?](repeating: nil, count: targets.count)
        var parts: [URL] = []
        var fds: [Int32] = []
        for (i, t) in targets.enumerated() {
            let dir = t.deletingLastPathComponent()
            let part = dir.appendingPathComponent("." + t.lastPathComponent + ".amanin-part")
            parts.append(part)
            do {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                errors[i] = "Couldn't make the folder: \(error.localizedDescription)"
                fds.append(-1)
                continue
            }
            unlink(part.path)
            let fd = Darwin.open(part.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd < 0 {
                errors[i] = "Couldn't write: \(errnoText())"
                fds.append(-1)
            } else {
                _ = fcntl(fd, F_NOCACHE, 1)
                fds.append(fd)
            }
        }

        func cleanup() {
            for fd in fds where fd >= 0 { Darwin.close(fd) }
            for p in parts { unlink(p.path) }
        }

        let buf = UnsafeMutableRawPointer.allocate(byteCount: IO.chunk, alignment: 16384)
        defer { buf.deallocate() }
        var hasher = XXH64()
        let errLock = NSLock()

        while true {
            if cancel.isCancelled { cleanup(); throw AppError.cancelled }
            let n = Darwin.read(inFD, buf, IO.chunk)
            if n < 0 {
                if errno == EINTR { continue }
                let msg = "Couldn't read the card: \(errnoText())"
                cleanup()
                throw AppError.io(msg)
            }
            if n == 0 { break }
            hasher.update(UnsafeRawBufferPointer(start: buf, count: n))

            let active = fds.indices.filter { fds[$0] >= 0 && errors[$0] == nil }
            if active.isEmpty { break }
            if active.count == 1 {
                let i = active[0]
                if let e = IO.writeAll(fds[i], buf, n) { errors[i] = "Couldn't write: \(e)" }
            } else {
                let raw = UnsafeRawPointer(buf)
                var local = errors
                DispatchQueue.concurrentPerform(iterations: active.count) { k in
                    let i = active[k]
                    if let e = IO.writeAll(fds[i], raw, n) {
                        errLock.lock(); local[i] = "Couldn't write: \(e)"; errLock.unlock()
                    }
                }
                errors = local
            }
            progress(Int64(n), "Copying")
        }

        for i in fds.indices where fds[i] >= 0 {
            if errors[i] == nil && fsync(fds[i]) != 0 { errors[i] = "Couldn't save to disk: \(errnoText())" }
            Darwin.close(fds[i])
            fds[i] = -1
        }
        let hash = XXH64.hex(hasher.digest())

        // Read every copy back from disk and compare.
        for i in targets.indices where errors[i] == nil {
            do {
                let vh = try IO.hashFile(parts[i].path, cancel: cancel) { n in progress(Int64(n), "Memverifikasi") }
                if vh != hash { errors[i] = "The copy doesn't match the card (different hash)" }
            } catch AppError.cancelled {
                cleanup()
                throw AppError.cancelled
            } catch {
                errors[i] = "Verification failed: \(error.localizedDescription)"
            }
        }

        var finals = [URL?](repeating: nil, count: targets.count)
        let srcAttrs = try? fm.attributesOfItem(atPath: src.path)
        for i in targets.indices {
            guard errors[i] == nil else { unlink(parts[i].path); continue }
            var attrs: [FileAttributeKey: Any] = [.modificationDate: mtime]
            if let c = srcAttrs?[.creationDate] { attrs[.creationDate] = c }
            try? fm.setAttributes(attrs, ofItemAtPath: parts[i].path)
            var final = targets[i]
            if fm.fileExists(atPath: final.path) { final = uniqueURL(final) }
            if rename(parts[i].path, final.path) != 0 {
                errors[i] = "Couldn't give the file its final name: \(errnoText())"
                unlink(parts[i].path)
            } else {
                finals[i] = final
            }
        }
        return Outcome(hash: hash, finals: finals, errors: errors)
    }

    static func uniqueURL(_ u: URL) -> URL {
        let dir = u.deletingLastPathComponent()
        let stem = u.deletingPathExtension().lastPathComponent
        let ext = u.pathExtension
        var n = 2
        while true {
            let name = ext.isEmpty ? "\(stem)_\(n)" : "\(stem)_\(n).\(ext)"
            let c = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: c.path) { return c }
            n += 1
        }
    }
}

// MARK: - Reports

enum Reporter {
    static func write(result: OffloadResult, scan: CardScan) -> [String] {
        let spec = result.spec
        let stamp = dateFormatter("yyyy-MM-dd HH.mm.ss").string(from: result.finishedAt ?? Date())
        let base = "\(spec.roll.isEmpty ? "Offload" : spec.roll) \(stamp)"
        let csv = makeCSV(result)
        let txt = makeText(result, scan: scan)
        var paths: [String] = []
        for root in spec.destinations where FileManager.default.fileExists(atPath: root) {
            let dir = URL(fileURLWithPath: root).appendingPathComponent(spec.projectRel).appendingPathComponent("_BCKUP Reports")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let t = dir.appendingPathComponent(base + ".txt")
                let c = dir.appendingPathComponent(base + ".csv")
                try txt.write(to: t, atomically: true, encoding: .utf8)
                try csv.write(to: c, atomically: true, encoding: .utf8)
                paths.append(t.path)
                paths.append(c.path)
            } catch {
                continue
            }
        }
        return paths
    }

    private static func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    static func makeCSV(_ r: OffloadResult) -> String {
        let dests = r.spec.destinations
        var header = ["file_di_kartu", "ukuran_byte", "xxh64", "type"]
        for (i, d) in dests.enumerated() {
            header.append("status_\(i + 1) (\(volumeName(forPath: d)))")
            header.append("lokasi_\(i + 1)")
        }
        if r.spec.cloud != nil { header.append("google_drive") }
        var lines = [header.map(q).joined(separator: ",")]
        for item in r.items {
            var row = [item.file.rel, String(item.file.size), item.hash ?? "", item.file.kind.label]
            for d in dests {
                let o = item.outcomes[d]
                row.append(o?.label ?? "")
                row.append(o?.rel ?? "")
            }
            if r.spec.cloud != nil {
                row.append(r.cloudOK == true && item.outcomes[dests.first ?? ""]?.rel != nil ? "Matches (MD5)" : (r.cloudOK == false ? "Failed" : ""))
            }
            lines.append(row.map(q).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func makeText(_ r: OffloadResult, scan: CardScan) -> String {
        let df = dateFormatter("yyyy-MM-dd HH:mm:ss")
        var s = "BCKUP OFFLOAD REPORT\n====================\n\n"
        s += "Card       : \(scan.name)\n"
        s += "Camera     : \(scan.camera)\(scan.model.map { " (\($0))" } ?? "")\n"
        s += "Project    : \(r.spec.projectRel)\n"
        s += "Roll       : \(r.spec.roll)\n"
        if let a = r.startedAt { s += "Mulai      : \(df.string(from: a))\n" }
        if let b = r.finishedAt { s += "Finished   : \(df.string(from: b))\n" }
        s += "Hash       : xxHash64 (XXH64), read back from the destination disk\n\n"
        s += "Destinations:\n"
        for (i, d) in r.spec.destinations.enumerated() {
            let ok = r.items.filter { $0.outcomes[d]?.isPresent == true }.count
            s += "  \(i == 0 ? "Utama " : "Backup") \(d)  —  \(ok)/\(r.items.count) files present\n"
        }
        if let c = r.spec.cloud { s += "  Cloud  \(c.target)  —  \(r.cloudMessage ?? "-")\n" }
        s += "\nFiles        : \(r.items.count) (\(byteText(scan.totalBytes)))\n"
        s += "Copied       : \(r.copiedCount) (\(byteText(r.copiedBytes)))\n"
        s += "Already there: \(r.existingOnlyCount)\n"
        s += "Failed       : \(r.failures)\n\n"
        let v = r.verdict
        s += "STATUS: \(v.title.uppercased())\n\(v.detail)\n"
        let failed = r.items.filter { $0.outcomes.values.contains(where: \.isFailure) }
        if !failed.isEmpty {
            s += "\nFailed files:\n"
            for f in failed {
                let msgs = f.outcomes.values.compactMap { if case .failed(let m) = $0 { return m } else { return nil } }
                s += "  \(f.file.rel): \(Set(msgs).joined(separator: "; "))\n"
            }
        }
        return s
    }
}

// MARK: - rclone

enum Cloud {
    /// BCKUP keeps its own Google Drive login, separate from any rclone setup the person already has.
    static let ownRemote = "amanin-gdrive"

    static var ownConfigPath: String {
        appSupportDir().appendingPathComponent("rclone.conf").path
    }

    static var ownConfigArgs: [String] { ["--config", ownConfigPath] }

    static var ownAccountConnected: Bool {
        guard let s = try? String(contentsOfFile: ownConfigPath, encoding: .utf8) else { return false }
        return s.contains("[\(ownRemote)]") && s.contains("token")
    }

    /// Opens the browser so whoever uses this Mac can sign in to their own Google account.
    /// Walks rclone's non-interactive config questions: accepts the shared client_id warning
    /// (only asked when no own client_id is given), uses the local browser for OAuth, and takes defaults otherwise.
    static func connectOwnAccount(clientID: String, clientSecret: String, cancel: CancelFlag, onLine: @escaping (String) -> Void) -> RunResult {
        guard let rc = findRclone() else { return RunResult(status: -1, all: ["rclone not found"]) }
        try? FileManager.default.createDirectory(atPath: (ownConfigPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        _ = run(rc, ownConfigArgs + ["config", "delete", ownRemote], cancel: CancelFlag()) { _ in }

        var base = ownConfigArgs + ["config", "create", ownRemote, "drive", "scope=drive"]
        if !clientID.isEmpty { base.append("client_id=\(clientID)") }
        if !clientSecret.isEmpty { base.append("client_secret=\(clientSecret)") }
        base.append("--non-interactive")

        var args = base
        for _ in 0..<12 {
            if cancel.isCancelled { return RunResult(status: -2, all: ["Cancelled"]) }
            let r = runJSON(rc, args, cancel: cancel)
            guard r.status == 0,
                  let data = r.stdout.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return RunResult(status: r.status == 0 ? -1 : r.status, all: r.stderr.isEmpty ? ["Couldn't read rclone's answer"] : r.stderr)
            }
            if let err = obj["Error"] as? String, !err.isEmpty { return RunResult(status: -1, all: [err]) }
            let state = obj["State"] as? String ?? ""
            if state.isEmpty { return RunResult(status: 0, all: ["Connected"]) }
            let option = obj["Option"] as? [String: Any]
            let name = option?["Name"] as? String ?? ""
            let answer: String
            switch name {
            case "config_shared_client_id", "config_is_local": answer = "true"
            default:
                if let d = option?["Default"] { answer = "\(d)".lowercased() == "<nil>" ? "" : "\(d)" } else { answer = "" }
            }
            if name == "config_is_local" { onLine("Waiting for sign-in in the browser…") }
            args = base + ["--continue", "--state", state, "--result", answer]
        }
        return RunResult(status: -1, all: ["rclone setup didn't finish"])
    }

    /// Like run(), but keeps stdout (JSON) apart from the log lines on stderr.
    static func runJSON(_ exe: String, _ args: [String], cancel: CancelFlag) -> (status: Int32, stdout: String, stderr: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let outBuf = DataBox(), errBuf = DataBox()
        out.fileHandleForReading.readabilityHandler = { outBuf.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { errBuf.append($0.availableData) }
        do { try p.run() } catch { return (-1, "", ["\(error.localizedDescription)"]) }
        while p.isRunning {
            if cancel.isCancelled { p.terminate() }
            usleep(200_000)
        }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        outBuf.append(out.fileHandleForReading.readDataToEndOfFile())
        errBuf.append(err.fileHandleForReading.readDataToEndOfFile())
        let errLines = String(decoding: errBuf.data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        return (p.terminationStatus, String(decoding: outBuf.data, as: UTF8.self), errLines)
    }

    final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    }

    static func disconnectOwnAccount() {
        guard let rc = findRclone() else { return }
        _ = run(rc, ownConfigArgs + ["config", "delete", ownRemote], cancel: CancelFlag()) { _ in }
    }

    /// Folders of "Google Drive for desktop" on this Mac (My Drive roots).
    static func desktopDriveFolders() -> [String] {
        let base = NSHomeDirectory() + "/Library/CloudStorage"
        let accounts = ((try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []).filter { $0.hasPrefix("GoogleDrive-") }
        var out: [String] = []
        for a in accounts {
            let acc = base + "/" + a
            let subs = (try? FileManager.default.contentsOfDirectory(atPath: acc)) ?? []
            if let my = subs.first(where: { ["My Drive", "Drive Saya", "Meine Ablage", "Mon Drive", "Mi unidad"].contains($0) }) {
                out.append(acc + "/" + my)
            } else {
                out.append(acc)
            }
        }
        return out
    }

    static func findRclone() -> String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("rclone").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let candidates = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone", "/usr/bin/rclone",
                          NSHomeDirectory() + "/bin/rclone", NSHomeDirectory() + "/.local/bin/rclone"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func listRemotes() -> [String] {
        guard let rc = findRclone() else { return [] }
        let r = run(rc, ["listremotes"], cancel: CancelFlag()) { _ in }
        guard r.status == 0 else { return [] }
        return r.all.filter { $0.hasSuffix(":") }
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = ""
        private(set) var all: [String] = []
        let onLine: (String) -> Void
        init(_ onLine: @escaping (String) -> Void) { self.onLine = onLine }
        func feed(_ data: Data) {
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            lock.lock()
            pending += s
            var out: [String] = []
            while let r = pending.rangeOfCharacter(from: CharacterSet(charactersIn: "\n\r")) {
                let line = String(pending[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                pending = String(pending[r.upperBound...])
                if !line.isEmpty { out.append(line) }
            }
            all.append(contentsOf: out)
            if all.count > 400 { all.removeFirst(all.count - 400) }
            lock.unlock()
            out.forEach(onLine)
        }
        func flush() {
            lock.lock()
            let rest = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            pending = ""
            if !rest.isEmpty { all.append(rest) }
            lock.unlock()
            if !rest.isEmpty { onLine(rest) }
        }
    }

    struct RunResult {
        let status: Int32
        let all: [String]
        var tail: [String] { Array(all.suffix(5)) }
    }

    static func run(_ exe: String, _ args: [String], cancel: CancelFlag, onLine: @escaping (String) -> Void) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let lines = Lines(onLine)
        pipe.fileHandleForReading.readabilityHandler = { h in lines.feed(h.availableData) }
        do {
            try p.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return RunResult(status: -1, all: ["Couldn't run rclone: \(error.localizedDescription)"])
        }
        while p.isRunning {
            if cancel.isCancelled { p.terminate() }
            usleep(200_000)
        }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        lines.feed(pipe.fileHandleForReading.readDataToEndOfFile())
        lines.flush()
        return RunResult(status: p.terminationStatus, all: lines.all)
    }

    static func percent(in line: String) -> Int? {
        guard let r = line.range(of: #"(\d{1,3})%"#, options: .regularExpression) else { return nil }
        return Int(line[r].dropLast())
    }

    static func cleanStats(_ line: String) -> String {
        if let r = line.range(of: "NOTICE:") { return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
        return line
    }
}
