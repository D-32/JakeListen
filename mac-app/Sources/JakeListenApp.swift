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
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.state == .recording ? "record.circle.fill" : "dog.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Centralized preference keys so the App and views stay in sync.
enum PrefKey {
    static let showMenuBarItem = "showMenuBarItem"
    static let participants = "participants"
}
