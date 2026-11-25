import AppKit
import SwiftUI

/// Sharing footage: AirDrop, WhatsApp, Email, Google Drive links (via rclone) and the system share menu.
@MainActor
final class ShareCenter: ObservableObject {
    enum State: Equatable {
        case idle
        case working(String)
        case done([String])
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var showing = false
    private(set) var subject = "Footage"

    static let emailLimit: Int64 = 20_000_000

    func airDrop(_ urls: [URL]) {
        guard let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: urls) else {
            alert("AirDrop isn't available", "Turn on Wi‑Fi and Bluetooth, then try again.")
            return
        }
        s.perform(withItems: urls)
    }

    func email(_ urls: [URL], subject: String, settings: AppSettings) {
        let size = totalSize(urls)
        if size > ShareCenter.emailLimit {
            let a = NSAlert()
            a.messageText = "Too big for email (\(byteText(size)))"
            a.informativeText = "Email is usually limited to about 20 MB. Send a Google Drive link instead?"
            a.addButton(withTitle: "Make a Google Drive link")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn { driveLink(urls, subject: subject, settings: settings) }
            return
        }
        guard let s = NSSharingService(named: .composeEmail) else {
            alert("Email isn't available", "Set up an account in Mail first.")
            return
        }
        s.subject = subject
        s.perform(withItems: urls)
    }

    func whatsApp(_ urls: [URL], subject: String, settings: AppSettings) {
        // WhatsApp for Mac adds a share extension; use it when present.
        if let svc = NSSharingService.sharingServices(forItems: urls).first(where: { $0.title.localizedCaseInsensitiveContains("whatsapp") }) {
            svc.perform(withItems: urls)
            return
        }
        let ids = ["net.whatsapp.WhatsApp", "desktop.WhatsApp", "WhatsApp"]
        if let app = ids.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            alert("Files copied", "Open a chat in WhatsApp and press ⌘V to paste the files. For big videos, a Google Drive link works better.")
            return
        }
        let a = NSAlert()
        a.messageText = "WhatsApp isn't installed on this Mac"
        a.informativeText = "Make a Google Drive link you can paste into a WhatsApp chat?"
        a.addButton(withTitle: "Make a Google Drive link")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { driveLink(urls, subject: subject, settings: settings) }
    }

    func showInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Uploads the items to Google Drive with rclone (skipped when already there) and makes "anyone with the link" links.
    func driveLink(_ urls: [URL], subject: String, settings: AppSettings) {
        self.subject = subject
        guard let spec = settings.cloudSpec(), settings.cloudIssue == nil else {
            state = .failed(settings.cloudIssue ?? "Google Drive isn't set up. Open Settings → Google Drive.")
            showing = true
            return
        }
        let rc = spec.rclone
        let extra = spec.extraArgs
        let base = spec.target
        let root = settings.primaryRoot.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        let stamp = dateFormatter("yyyy-MM-dd").string(from: Date())
        state = .working("Menyiapkan…")
        showing = true

        Task.detached(priority: .userInitiated) { [weak self] in
            var links: [String] = []
            var failure: String?
            for (i, u) in urls.enumerated() {
                let p = u.standardizedFileURL.path
                let remote: String
                if let root, p.hasPrefix(root + "/") {
                    remote = base + "/" + String(p.dropFirst(root.count + 1))
                } else {
                    remote = base + "/_Dibagikan/" + stamp + "/" + u.lastPathComponent
                }
                await MainActor.run { self?.state = .working("Uploading \(i + 1) of \(urls.count): \(u.lastPathComponent)") }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: p, isDirectory: &isDir)
                let up = Cloud.run(rc, extra + [isDir.boolValue ? "copy" : "copyto", p, remote], cancel: CancelFlag()) { _ in }
                guard up.status == 0 else {
                    failure = "Upload failed: \(up.tail.last ?? "kode \(up.status)")"
                    break
                }
                await MainActor.run { self?.state = .working("Making link \(i + 1) of \(urls.count)…") }
                let l = Cloud.run(rc, extra + ["link", remote], cancel: CancelFlag()) { _ in }
                guard l.status == 0, let link = l.all.last(where: { $0.hasPrefix("http") }) else {
                    failure = "Couldn't make the link: \(l.tail.last ?? "kode \(l.status)")"
                    break
                }
                links.append(urls.count > 1 ? "\(u.lastPathComponent): \(link)" : link)
            }
            let result = links
            let err = failure
            await MainActor.run {
                if let err {
                    self?.state = .failed(err)
                } else {
                    self?.state = .done(result)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.joined(separator: "\n"), forType: .string)
                }
            }
        }
    }

    func sendText(viaWhatsApp text: String) {
        var comps = URLComponents()
        comps.scheme = "whatsapp"
        comps.host = "send"
        comps.queryItems = [URLQueryItem(name: "text", value: text)]
        if let u = comps.url, NSWorkspace.shared.urlForApplication(toOpen: u) != nil {
            NSWorkspace.shared.open(u)
        } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            alert("WhatsApp isn't installed", "Link copied. Paste it into the chat.")
        }
    }

    func sendText(viaEmail text: String) {
        guard let s = NSSharingService(named: .composeEmail) else { return }
        s.subject = subject
        s.perform(withItems: [text])
    }

    private func totalSize(_ urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey])
                while let f = en?.nextObject() as? URL {
                    total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            } else {
                total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

// MARK: - Menu items

struct ShareMenuItems: View {
    @EnvironmentObject var app: AppState
    let urls: [URL]
    var subject = "Footage"

    var body: some View {
        Group {
            Button { app.share.airDrop(urls) } label: {
                Label("AirDrop", systemImage: "dot.radiowaves.left.and.right")
            }
            Button { app.share.whatsApp(urls, subject: subject, settings: app.settings) } label: {
                Label("WhatsApp", systemImage: "message")
            }
            Button { app.share.email(urls, subject: subject, settings: app.settings) } label: {
                Label("Email", systemImage: "envelope")
            }
            Button { app.share.driveLink(urls, subject: subject, settings: app.settings) } label: {
                Label("Link Google Drive", systemImage: "link")
            }
            Divider()
            ShareLink(items: urls) {
                Label("More…", systemImage: "square.and.arrow.up")
            }
            Button { app.share.showInFinder(urls) } label: {
                Label("Show in Finder", systemImage: "folder")
            }
        }
        .disabled(urls.isEmpty)
    }
}

struct ShareButton: View {
    let urls: [URL]
    var subject = "Footage"
    var title = "Share"

    var body: some View {
        Menu {
            ShareMenuItems(urls: urls, subject: subject)
        } label: {
            Label(title, systemImage: "square.and.arrow.up")
        }
        .fixedSize()
        .disabled(urls.isEmpty)
    }
}

// MARK: - Drive link sheet

struct ShareSheetHost: View {
    @ObservedObject var share: ShareCenter

    var body: some View {
        Color.clear
            .sheet(isPresented: $share.showing) {
                DriveLinkSheet(share: share)
            }
    }
}

struct DriveLinkSheet: View {
    @ObservedObject var share: ShareCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Link Google Drive", systemImage: "link").font(.title2.weight(.semibold))
            switch share.state {
            case .idle:
                EmptyView()
            case .working(let msg):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(msg).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Text("Files already on Drive aren't uploaded again.").font(.caption).foregroundStyle(.secondary)
            case .done(let links):
                let text = links.joined(separator: "\n")
                Label("Link copied to the clipboard.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                ScrollView {
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 160)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                Text("Anyone with this link can open the files.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button { share.sendText(viaWhatsApp: text) } label: { Label("Send via WhatsApp", systemImage: "message") }
                    Button { share.sendText(viaEmail: text) } label: { Label("Send via Email", systemImage: "envelope") }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
            case .failed(let m):
                Label(m, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Close") { share.showing = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled({ if case .working = share.state { return true } else { return false } }())
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
