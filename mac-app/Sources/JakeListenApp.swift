// JakeListenApp — app entry point. Provides both a menu-bar item (for quick
// start/stop) and a main window (recordings + transcripts), per the design.
//
// The menu-bar item is optional: bound to the "showMenuBarItem" preference via
// MenuBarExtra's `isInserted`, so it can be hidden (and re-shown from the window
// or Settings ⌘,).

import SwiftUI

@main
struct JakeListenApp: App {
    @StateObject private var model = AppModel()
    @AppStorage(PrefKey.showMenuBarItem) private var showMenuBarItem = true

    var body: some Scene {
        Window("JakeListen", id: "main") {
            MainWindow()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 460)
        }
        .defaultSize(width: 900, height: 560)

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra(isInserted: $showMenuBarItem) {
            MenuBarContent(meter: model.meter)
                .environmentObject(model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Menu-bar icon. Shows the dog normally, a red dot while recording, and a
/// warning triangle if the mic has gone silent — a glanceable "it's not
/// hearing anything" signal even when the window is closed.
private struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meter: AudioMeter

    init(model: AppModel) {
        self.model = model
        self.meter = model.meter
    }

    var body: some View {
        if model.state == .recording {
            Image(systemName: meter.noSignal ? "exclamationmark.triangle.fill" : "record.circle.fill")
        } else {
            Image(systemName: "dog.fill")
        }
    }
}

/// Centralized preference keys so the App and views stay in sync.
enum PrefKey {
    static let showMenuBarItem = "showMenuBarItem"
    static let participants = "participants"
}
