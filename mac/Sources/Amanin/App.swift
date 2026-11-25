import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("--settings-cloud") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    /// Folders, cards or files dropped on the Dock icon or opened with BCKUP.
    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .amaninOpenURLs, object: urls)
    }
}

struct AmaninApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("BCKUP", id: "main") {
            MainView()
                .environmentObject(state)
                .frame(minWidth: 860, minHeight: 600)
        }
        .defaultSize(width: 1080, height: 760)
        .commands {
            CommandMenu("Go") {
                Button("Home") { state.selection = Nav.home; state.showMainWindow() }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Projects") { state.selection = Nav.projects; state.showMainWindow() }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Sort downloads") { state.selection = Nav.downloads; state.showMainWindow() }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

