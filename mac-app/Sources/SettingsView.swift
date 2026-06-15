// SettingsView — the standard ⌘, preferences pane. Currently just the
// menu-bar visibility toggle (so a hidden item can always be brought back).

import SwiftUI

struct SettingsView: View {
    @AppStorage(PrefKey.showMenuBarItem) private var showMenuBarItem = true
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Show menu-bar icon", isOn: $showMenuBarItem)
            Text("Turn this off to hide the 🐕 from the menu bar. You can still record from this window.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            LabeledContent("CLI") {
                Text(model.cliPath ?? "not found")
                    .foregroundStyle(model.cliPath == nil ? .red : .secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
