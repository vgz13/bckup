import Foundation

/// Command-line mode, used for testing the engine without the window:
///   BCKUP --cli --source <card> --dest <root> [--dest <backup>] --client X --project Y --roll R
///          [--fast] [--no-skip] [--flat] [--catalog path] [--cloud remote: --cloud-path Footage]
///   BCKUP --cli --hash <file>
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        var source: String?
        var dests: [String] = []
        var client = ""
        var project = "Tes"
        var roll = "Roll 1"
        var skip = true
        var mode = CheckMode.thorough
        var separate = true
        var assets = false
        var catalogPath: String?
        var cloudRemote: String?
        var cloudPath = "Footage"

        var i = 0
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--source": source = next()
            case "--dest": if let d = next() { dests.append(d) }
            case "--client": client = next() ?? ""
            case "--project": project = next() ?? project
            case "--roll": roll = next() ?? roll
            case "--fast": mode = .fast
            case "--no-skip": skip = false
            case "--flat": separate = false
            case "--assets": assets = true
            case "--catalog": catalogPath = next()
            case "--cloud": cloudRemote = next()
            case "--cloud-path": cloudPath = next() ?? cloudPath
            case "--connect-drive":
                print("Opening the browser to sign in to Google…")
                let r = Cloud.connectOwnAccount(clientID: "", clientSecret: "", cancel: CancelFlag()) { print($0) }
                print(Cloud.ownAccountConnected ? "CONNECTED" : "FAILED: \(r.all.joined(separator: " | "))")
                return Cloud.ownAccountConnected ? 0 : 1
            case "--hash":
                guard let f = next() else { return 2 }
                do { print(try IO.hashFile(f, cancel: nil)); return 0 } catch { print(error.localizedDescription); return 1 }
            default: break
            }
            i += 1
        }
        guard let source, !dests.isEmpty else {
            print("Usage: BCKUP --cli --source <card> --dest <folder> [--dest <backup>] --client X --project Y --roll R")
            return 2
        }

        do {
            let scan = try CardScanner.scan(URL(fileURLWithPath: source))
            print("Card   : \(scan.name) — \(scan.camera)\(scan.model.map { " (\($0))" } ?? "")")
            print("Holds  : \(scan.files.count) files, \(byteText(scan.totalBytes))")

            let catalog = Catalog(url: catalogPath.map { URL(fileURLWithPath: $0) } ?? Catalog.defaultURL)
            var cloud: CloudSpec?
            if let r = cloudRemote {
                guard let rc = Cloud.findRclone() else { print("rclone not found"); return 1 }
                cloud = CloudSpec(rclone: rc, remote: r, path: cloudPath)
            }
            let spec = OffloadSpec(
                source: scan.root,
                clientFolder: client.isEmpty ? nil : cleanName(client),
                projectFolder: cleanName(project),
                roll: cleanName(roll),
                destinations: dests,
                separateByType: separate,
                kindFolders: AppSettings().kindFolders,
                skipExisting: skip,
                checkMode: mode,
                cloud: cloud,
                assets: assets ? AppSettings().assetLayout : nil
            )
            let engine = OffloadEngine(catalog: catalog, cancel: CancelFlag())
            let plan = try engine.plan(spec: spec, scan: scan) { _ in }
            for s in plan.summaries {
                print("Plan   : \(s.root) → \(s.skip) skipped, \(s.copy) to copy (\(byteText(s.bytes)))\(s.renamed > 0 ? ", \(s.renamed) diberi akhiran" : "")")
            }
            let started = Date()
            var r = engine.execute(plan: plan) { _ in }
            if cloud != nil && r.failures == 0 { engine.upload(result: &r) { _ in } }
            r.startedAt = started
            r.finishedAt = Date()
            r.reports = Reporter.write(result: r, scan: scan)
            print("Result : \(r.copiedCount) copied, \(r.existingOnlyCount) already there, \(r.failures) failed")
            if let m = r.cloudMessage { print("Cloud  : \(m)") }
            print("STATUS : \(r.verdict.title) — \(r.verdict.detail)")
            for p in r.reports where p.hasSuffix(".txt") { print("Report : \(p)") }
            return r.failures == 0 ? 0 : 1
        } catch {
            print("Error: \(error.localizedDescription)")
            return 1
        }
    }
}
