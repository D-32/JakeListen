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
        // NOTE: these menu items deliberately have FIXED titles and no
        // `.disabled(…)`. Both used to be computed from @MainActor model state
        // (`model.isRecording`, `model.updater.phase.isBusy`), which made macOS
        // re-enter Swift's main-executor check every time it validated the menu
        // bar. On macOS 26/27 that path segfaults inside Apple's own code
        // (MenuBarClientCore → swift_task_isCurrentExecutor → _isSameExecutor),
        // taking the app — and any recording in progress — with it. Keeping the
        // items static keeps our model off that path. The actions themselves are
        // no-ops when they don't apply, so nothing is lost but a prettier title.
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await model.updater.check(manual: true) }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Start / Stop Recording") {
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
