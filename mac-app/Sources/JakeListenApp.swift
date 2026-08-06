// JakeListenApp — app entry point. A single-window Mac app; the record button and
// settings live in the window's toolbar.

import SwiftUI

@main
struct JakeListenApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("JakeListen", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await model.updater.check(manual: true) }
                }
                .disabled(model.updater.phase.isBusy)
            }
            CommandGroup(replacing: .newItem) {
                Button(model.isRecording ? "Stop Recording" : "New Recording") {
                    model.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
        }

        Settings {
            SettingsView(settings: model.settings)
        }
    }
}
