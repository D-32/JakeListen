// SettingsView — Gemini API key (required), the model, and an optional domain
// primer. Doubles as first-run onboarding when no key is set yet.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 30)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.hasAPIKey ? "Settings" : "Welcome to JakeListen")
                        .font(.title2.weight(.semibold))
                    Text(settings.hasAPIKey
                         ? "Your key stays in your Mac's Keychain."
                         : "Paste your free Gemini API key to get started.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section {
                    SecureField("AIza…", text: $settings.apiKey)
                        .textFieldStyle(.roundedBorder)
                    Link("Get a free key at Google AI Studio ↗",
                         destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                        .font(.callout)
                } header: {
                    Text("Gemini API key")
                } footer: {
                    Text("Audio goes straight from your Mac to Google under your key — there's no JakeListen server in between.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Model") {
                    TextField("Model", text: $settings.model, prompt: Text(AppSettings.defaultModel))
                        .textFieldStyle(.roundedBorder)
                    Text("Any audio-capable Gemini model. Default: \(AppSettings.defaultModel).")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    TextEditor(text: $settings.context)
                        .frame(height: 70)
                        .font(.body)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                } header: {
                    Text("Domain context (optional)")
                } footer: {
                    Text("Names, product terms, or jargon Gemini should spell correctly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(settings.hasAPIKey ? "Done" : "Get Started") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!settings.hasAPIKey)
            }
            .padding(16)
        }
        .frame(width: 460, height: 560)
    }
}
