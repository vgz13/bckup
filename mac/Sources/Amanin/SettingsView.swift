import SwiftUI

struct SettingsView: View {
    @State private var tab = ProcessInfo.processInfo.arguments.contains("--settings-cloud") ? "cloud" : "dest"

    var body: some View {
        TabView(selection: $tab) {
            DestinationsSettings().tabItem { Label("Destinations", systemImage: "externaldrive") }.tag("dest")
            FolderSettings().tabItem { Label("Folder layout", systemImage: "folder") }.tag("folder")
            CheckSettings().tabItem { Label("Pengecekan", systemImage: "checkmark.shield") }.tag("check")
            CloudSettings().tabItem { Label("Google Drive", systemImage: "icloud") }.tag("cloud")
        }
        .frame(width: 640, height: 560)
    }
}

struct DestinationsSettings: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.settings.primaryRoot.map { volumeName(forPath: $0) } ?? "Not chosen").bold()
                        Text(app.settings.primaryRoot ?? "Where all your footage lives")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Choose…") { app.choosePrimary() }
                }
            } header: {
                Text("Main folder")
            } footer: {
                Text("Project folders are made inside this folder.")
            }

            Section {
                if app.settings.backupRoots.isEmpty {
                    Text("No backup drive yet").foregroundStyle(.secondary)
                }
                ForEach(app.settings.backupRoots, id: \.self) { b in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(volumeName(forPath: b)).bold()
                            Text(b).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) { app.removeBackup(b) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove from list (files on the drive aren't touched)")
                    }
                }
                Button("Add backup drive…") { app.addBackup() }
            } header: {
                Text("Backup")
            } footer: {
                Text("Cards are copied to the main folder and every connected backup at once, with the same folder layout.")
            }

            Section {
                Toggle("Show the menu bar panel when a card goes in", isOn: $app.settings.autoOpenOnCard)
                if !app.settings.hiddenVolumes.isEmpty {
                    Button("Show hidden drives again (\(app.settings.hiddenVolumes.count))") {
                        app.settings.hiddenVolumes = []
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct FolderSettings: View {
    @EnvironmentObject var app: AppState

    private let formats = ["dd.MM.yy", "dd.MM.yyyy", "yyyy-MM-dd", "yyMMdd", "dd-MM-yyyy"]

    var body: some View {
        Form {
            Section("Susunan") {
                Toggle("Make a folder per client", isOn: $app.settings.useClientFolder)
                Picker("Project folder name", selection: $app.settings.datePosition) {
                    ForEach(DatePosition.allCases) { Text($0.label).tag($0) }
                }
                Picker("Date format", selection: $app.settings.dateFormat) {
                    ForEach(formats, id: \.self) { f in
                        Text("\(dateFormatter(f).string(from: Date()))  (\(f))").tag(f)
                    }
                }
                .disabled(app.settings.datePosition == .none)
            }
            Section("File types") {
                Toggle("Split into a folder per type", isOn: $app.settings.separateByType)
                TextField("Video folder", text: $app.settings.videoFolder)
                TextField("Photo folder", text: $app.settings.photoFolder)
                TextField("Audio folder", text: $app.settings.audioFolder)
            }
            Section("Contoh") {
                Text(example)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var example: String {
        let s = app.settings
        var parts = [volumeName(forPath: s.primaryRoot ?? "/Main folder")]
        if s.useClientFolder { parts.append("Client Name") }
        parts.append(s.projectFolderName(project: "Project Name", date: Date()))
        if s.separateByType { parts.append(s.videoFolder) }
        parts.append("Sony A7")
        parts.append("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        return parts.joined(separator: "/")
    }
}

struct CheckSettings: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Only copy files that aren't there yet", isOn: $app.settings.skipExisting)
                Picker("Cara mengecek", selection: $app.settings.checkMode) {
                    ForEach(CheckMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .disabled(!app.settings.skipExisting)
                Text(app.settings.checkMode.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Default for new cards")
            } footer: {
                Text("Existing files are recognised anywhere in the main folder, so footage already offloaded to another project isn't copied twice. Existing files are never overwritten.")
            }
            Section("Verifikasi") {
                Label("Every copied file is read back from the destination disk and checked with xxHash64.", systemImage: "checkmark.shield")
                Label("Cards are only ever read. BCKUP never changes or deletes anything on a card.", systemImage: "lock")
                Label("Unfinished files are saved under a temporary name, so a half-copied file never has its real name.", systemImage: "doc.badge.clock")
            }
            .font(.callout)
        }
        .formStyle(.grouped)
    }
}

struct CloudSettings: View {
    @EnvironmentObject var app: AppState
    @State private var remotes: [String] = []
    @State private var connected = Cloud.ownAccountConnected
    @State private var connecting = false
    @State private var connectMessage: String?
    @State private var connectCancel = CancelFlag()
    @State private var showAdvanced = false
    @State private var desktopFolders: [String] = []

    var body: some View {
        Form {
            Section {
                Toggle("Upload to Google Drive after copying", isOn: $app.settings.cloudEnabled)
                Picker("Connect with", selection: $app.settings.cloudMode) {
                    ForEach(CloudMode.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Everyone who uses BCKUP signs in with their own Google account. The sign-in is kept for BCKUP only, separate from any other rclone setup on this Mac.")
            }

            if app.settings.cloudMode == .ownAccount {
                Section("Google account") {
                    HStack(spacing: 10) {
                        Image(systemName: connected ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                            .font(.title2)
                            .foregroundStyle(connected ? Color.green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connected ? "Connected" : "Not connected").fontWeight(.medium)
                            Text(connected ? "Uploads and links use the account you signed in with." : "Click Connect, then sign in in your browser.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if connecting {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { connectCancel.cancel() }
                        } else if connected {
                            Button("Switch account…") { connect() }
                            Button("Putuskan", role: .destructive) {
                                Cloud.disconnectOwnAccount()
                                connected = Cloud.ownAccountConnected
                                connectMessage = "Account disconnected from BCKUP."
                                app.objectWillChange.send()
                            }
                        } else {
                            Button("Connect Google account…") { connect() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    if let connectMessage {
                        Text(connectMessage).font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Lanjutan: Client ID sendiri", isExpanded: $showAdvanced) {
                        TextField("Client ID", text: $app.settings.cloudClientID)
                        SecureField("Client secret", text: $app.settings.cloudClientSecret)
                        Text("Recommended for regular use. rclone's built-in client ID is shared by many people and is being retired. Create one in Google Cloud Console (OAuth client, type Desktop app), enter it here, then connect again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Picker("Remote", selection: $app.settings.cloudRemote) {
                        Text("Choose…").tag("")
                        ForEach(remotes, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(remotes.isEmpty)
                } header: {
                    Text("Remote rclone")
                } footer: {
                    Text("Uses a remote from this Mac's own rclone setup. For people who already use rclone.")
                }
            }

            Section {
                TextField("Folder on Drive", text: $app.settings.cloudPath)
                LabeledContent("Contoh", value: app.settings.cloudDisplay + " › Client › Project › …")
                LabeledContent("rclone", value: Cloud.findRclone().map { $0.contains(".app/") ? "bawaan BCKUP" : $0 } ?? "not found")
            } footer: {
                Text("Only files from the card being copied are uploaded. After uploading, each file's MD5 is checked. If they match, Drive counts as a copy.")
            }

            Section {
                if desktopFolders.isEmpty {
                    Text("Google Drive for desktop isn't installed on this Mac.").foregroundStyle(.secondary)
                }
                ForEach(desktopFolders, id: \.self) { f in
                    let target = f + "/BCKUP Backup"
                    HStack {
                        Image(systemName: "externaldrive.connected.to.line.below").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(accountName(f)).fontWeight(.medium)
                            Text(target).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if app.settings.backupRoots.contains(target) {
                            Label("In use", systemImage: "checkmark").foregroundStyle(.green)
                        } else {
                            Button("Use as backup") {
                                try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
                                app.settings.backupRoots.append(target)
                            }
                        }
                    }
                }
            } header: {
                Text("No sign-in: Google Drive for desktop folder")
            } footer: {
                Text("If Google Drive for desktop is installed, its folder can be used as an ordinary backup drive. BCKUP copies and verifies into it, then Google Drive uploads in the background. Make sure syncing has finished before you format a card.")
            }
        }
        .formStyle(.grouped)
        .task {
            connected = Cloud.ownAccountConnected
            desktopFolders = Cloud.desktopDriveFolders()
            remotes = await Task.detached { Cloud.listRemotes() }.value
        }
    }

    private func accountName(_ folder: String) -> String {
        let comps = folder.components(separatedBy: "/")
        let acc = comps.first { $0.hasPrefix("GoogleDrive-") }?.replacingOccurrences(of: "GoogleDrive-", with: "") ?? "Google Drive"
        return "Google Drive (\(acc))"
    }

    private func connect() {
        connecting = true
        connectMessage = "Your browser opened. Sign in with your Google account, then click Allow."
        let flag = CancelFlag()
        connectCancel = flag
        let id = app.settings.cloudClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = app.settings.cloudClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        Task.detached(priority: .userInitiated) {
            let r = Cloud.connectOwnAccount(clientID: id, clientSecret: secret, cancel: flag) { _ in }
            let ok = Cloud.ownAccountConnected
            await MainActor.run {
                connecting = false
                connected = ok
                if ok {
                    connectMessage = "Google account connected."
                    if !app.settings.cloudEnabled { app.settings.cloudEnabled = true }
                } else if flag.isCancelled {
                    connectMessage = "Cancelled."
                } else {
                    connectMessage = "Not connected: \(r.tail.last ?? "login tidak selesai")"
                }
                app.objectWillChange.send()
            }
        }
    }
}
