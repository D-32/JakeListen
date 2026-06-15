// MenuBarContent — rendered as a native macOS menu (MenuBarExtra .menu style),
// so it looks like any system menu-bar item (Tailscale, Wi-Fi, etc.): plain
// rows that highlight on hover, separators, and ⌘ shortcuts.

import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status line (disabled → greyed info row, like "Connected")
        Text(statusLine)

        // Primary action
        Button(actionLabel) { model.toggle() }
            .keyboardShortcut("r")
            .disabled(model.state == .processing || model.cliPath == nil)

        Divider()

        Button("Open Window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Open Recordings Folder") { model.revealInFinder() }

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit JakeListen") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var actionLabel: String {
        switch model.state {
        case .idle: return "Start Recording"
        case .recording: return "Stop & Process"
        case .processing: return "Processing…"
        }
    }

    private var statusLine: String {
        switch model.state {
        case .recording: return "● Recording — \(model.elapsedText)"
        case .processing: return model.status
        case .idle: return model.cliPath == nil ? "CLI not found" : "Ready"
        }
    }
}
