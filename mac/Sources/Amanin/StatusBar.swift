import AppKit
import Combine
import SwiftUI

// MARK: - Menu bar item + panel

/// Menu-bar icon that opens a small panel. Unlike MenuBarExtra it can open by itself when a card goes in.
@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private weak var app: AppState?
    private var watch: AnyCancellable?

    init(app: AppState) {
        self.app = app
        super.init()
        let host = NSHostingController(rootView: StatusPanel().environmentObject(app))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading
        updateButton()
        watch = app.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateButton() }
        }
    }

    private func updateButton() {
        guard let app, let button = item.button else { return }
        let img = NSImage(systemSymbolName: app.menuSymbol, accessibilityDescription: "BCKUP")
        img?.isTemplate = true
        button.image = img
        button.title = app.busyPercent.map { " \($0)%" } ?? ""
    }

    @objc private func toggle() {
        popover.isShown ? popover.performClose(nil) : show()
    }

    func show() {
        guard let button = item.button else { return }
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() { popover.performClose(nil) }
}

struct StatusPanel: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(app.notices) { n in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(n.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("OK") { app.notices.removeAll { $0.id == n.id } }
                        .controlSize(.small)
                }
                .padding(12)
                .background(Color.orange.opacity(0.12))
                Divider()
            }

            if app.settings.primaryRoot == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("BCKUP isn't set up yet").font(.headline)
                    Text("Choose a main folder for your footage first.").foregroundStyle(.secondary)
                    Button("Open BCKUP") { openApp() }
                }
                .padding(16)
            } else if app.cards.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No card").font(.headline)
                    Text("Plug in a camera card and BCKUP checks it right away.").foregroundStyle(.secondary)
                }
                .padding(16)
            } else {
                ForEach(app.cards) { card in
                    CardStatusBlock(job: app.job(for: card.url), compact: true, onOpen: {
                        app.selection = card.url
                        openApp()
                    })
                    .padding(16)
                    Divider()
                }
            }

            let drives = app.pluggedDrives()
            if !drives.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Also plugged in").font(.caption).foregroundStyle(.secondary)
                    ForEach(drives, id: \.url) { d in
                        HStack(spacing: 8) {
                            Image(systemName: "externaldrive").foregroundStyle(.secondary).frame(width: 16)
                            Text(d.name).lineLimit(1)
                            Spacer()
                            Text(d.role).font(.callout).foregroundStyle(d.role == "Working drive" || d.role == "Backup drive" ? .primary : .secondary)
                        }
                        .font(.callout)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
            }

            HStack {
                Button("Open BCKUP") { openApp() }
                    .buttonStyle(.link)
                Spacer()
                Menu {
                    SettingsLink { Text("Settings…") }
                    Divider()
                    Button("Quit BCKUP") { quit() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Button("Close") { app.statusBar?.close() }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 360)
        .onAppear {
            for c in app.cards { app.job(for: c.url).scanIfNeeded() }
        }
    }

    private func openApp() {
        app.statusBar?.close()
        app.showMainWindow()
    }

    private func quit() {
        if app.isBusy {
            let a = NSAlert()
            a.messageText = "A copy is still running"
            a.informativeText = "If you quit now, unfinished files will need copying again. Nothing on the card changes."
            a.addButton(withTitle: "Tetap jalan")
            a.addButton(withTitle: "Quit")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { return }
        }
        NSApp.terminate(nil)
    }
}

// MARK: - One card's status (menu-bar panel and home screen)

struct CardStatusBlock: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var job: OffloadJob
    var compact = false
    var onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                if let first = previewFile {
                    Thumb(url: first.url, size: CGSize(width: 48, height: 48))
                        .clipShape(Circle())
                } else {
                    Image(systemName: "sdcard").font(.title2).foregroundStyle(.secondary).frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.displayName).font(.headline).lineLimit(1)
                    Text(job.cardStatus?.headline ?? (job.scan.map { "\($0.camera) · \($0.files.count) files" } ?? "Reading the card…"))
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }

            if let st = job.cardStatus {
                HStack(spacing: 8) {
                    Image(systemName: st.symbol).foregroundStyle(st.color)
                    Text(st.title).fontWeight(.semibold).foregroundStyle(st.color)
                    Spacer()
                    if job.quickRunning || job.isBusy {
                        ProgressView().controlSize(.small)
                    } else if st.safe {
                        Button("Eject") { job.eject() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button(job.quick?.filesToCopy ?? 0 > 0 && job.stage != .done ? "Copy now" : "Open") { onOpen() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                Text(st.detail)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(st.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

                if !job.quickVerified, job.stage != .done, !job.isBusy, let q = job.quick, q.summaries.contains(where: { $0.copy == 0 }) {
                    Button(job.quickRunning ? "Comparing contents…" : "Check file contents (hash) to be sure") { job.runQuickCheck(thorough: true) }
                        .buttonStyle(.link)
                        .font(.callout)
                        .disabled(job.quickRunning)
                }
                if job.quickRunning, job.quickProgress.total > 0 {
                    ProgressView(value: job.quickProgress.fraction).controlSize(.small)
                }
            }
        }
        .onAppear { job.scanIfNeeded() }
    }

    private var previewFile: CardFile? {
        job.scan?.files.first { ["jpg", "jpeg", "heic", "hif"].contains($0.url.pathExtension.lowercased()) && !$0.rel.uppercased().contains("THMBNL") }
            ?? job.scan?.files.first { $0.kind == .video }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Home").font(.title.weight(.semibold))
                if app.cards.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Plug in a camera card").font(.title3.weight(.medium))
                        Text("BCKUP checks right away whether its contents are already on your drives and tells you from the menu bar. You can also drag a card, folder or files onto this window.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Choose a source folder…") { app.chooseManualSource() }
                            .padding(.top, 4)
                    }
                } else {
                    Panel(title: "Plugged-in cards") {
                        ForEach(Array(app.cards.enumerated()), id: \.element.id) { i, card in
                            if i > 0 { Divider() }
                            CardStatusBlock(job: app.job(for: card.url), onOpen: { app.selection = card.url })
                        }
                    }
                }
                let drives = app.pluggedDrives()
                if !drives.isEmpty {
                    Panel(title: "Drive") {
                        ForEach(drives, id: \.url) { d in
                            HStack {
                                Text(d.name)
                                Spacer()
                                Text(d.role).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Home")
    }
}
