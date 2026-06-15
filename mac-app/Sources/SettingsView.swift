// SettingsView — the standard ⌘, preferences pane. Currently just the
// menu-bar visibility toggle (so a hidden item can always be brought back).

import SwiftUI

struct SettingsView: View {
    @AppStorage(PrefKey.showMenuBarItem) private var showMenuBarItem = true
    @AppStorage(PrefKey.participants) private var participants = ""
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Show menu-bar icon", isOn: $showMenuBarItem)
            Text("Turn this off to hide the 🐕 from the menu bar. You can still record from this window.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                TextField("Usual participants", text: $participants, prompt: Text("e.g. Alice, Bob, Carol"))
                    .textFieldStyle(.roundedBorder)
                Text("Comma-separated names of people often on your calls. JakeListen uses these to label speakers by name instead of “Speaker 1/2.”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            LabeledContent("API key") {
                HStack {
                    Text(model.hasAPIKey ? "configured" : "not set")
                        .foregroundStyle(model.hasAPIKey ? .green : .red)
                    Button("Set up / change…") { model.showOnboarding = true }
                }
            }

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
