// MenuBarContent — the popover shown when clicking the menu-bar icon.
// Quick record/stop plus shortcuts to the window and the recordings folder.

import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PrefKey.showMenuBarItem) private var showMenuBarItem = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "dog.fill")
                Text("JakeListen").font(.headline)
                Spacer()
            }

            Divider()

            // Big primary action
            Button(action: model.toggle) {
                HStack {
                    Image(systemName: buttonIcon)
                    Text(buttonLabel)
                    Spacer()
                    if model.state == .recording {
                        Text(model.elapsedText)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(model.state == .recording ? .red : .accentColor)
            .disabled(model.state == .processing || model.cliPath == nil)

            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Divider()

            Button("Open Window") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Open Recordings Folder", action: model.revealInFinder)

            Button("Hide Menu-Bar Icon") {
                showMenuBarItem = false
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .help("Re-enable it from the window toolbar or Settings (⌘,)")

            Divider()

            Button("Quit JakeListen") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 260)
    }

    private var buttonLabel: String {
        switch model.state {
        case .idle: return "Start Recording"
        case .recording: return "Stop & Process"
        case .processing: return "Processing…"
        }
    }

    private var buttonIcon: String {
        switch model.state {
        case .idle: return "record.circle"
        case .recording: return "stop.circle.fill"
        case .processing: return "hourglass"
        }
    }
}
