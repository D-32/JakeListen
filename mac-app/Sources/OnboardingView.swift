// OnboardingView — first-run setup for non-technical users. Paste a Gemini API
// key (saved to the CLI config), set usual participants, and follow a built-in
// step-by-step guide to create a free Google API key.

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(PrefKey.participants) private var participants = ""
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey = ""
    @State private var showGuide = true

    private let keyURL = URL(string: "https://aistudio.google.com/apikey")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                groupBox("1 · Your Google Gemini API key") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("JakeListen uses Google's Gemini AI to transcribe and summarize your calls. You need a free API key.")
                            .foregroundStyle(.secondary)

                        Button {
                            NSWorkspace.shared.open(keyURL)
                        } label: {
                            Label("Open Google AI Studio (get a key)", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)

                        DisclosureGroup("Step-by-step: how to create a key", isExpanded: $showGuide) {
                            tutorial
                        }
                        .padding(.top, 4)

                        Text("Paste your key here (it starts with “AIza”):")
                            .padding(.top, 6)
                        SecureField("AIza…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                        if model.hasAPIKey && apiKey.isEmpty {
                            Label("A key is already saved — you can leave this blank.", systemImage: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                }

                groupBox("2 · Who's usually on your calls? (optional)") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Usual participants", text: $participants, prompt: Text("e.g. Alice, Bob, Carol"))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 360)
                        Text("Comma-separated names. JakeListen uses these to label speakers by name instead of “Speaker 1/2.”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Spacer()
                    Button("Skip for now") { dismiss() }
                    Button("Save & Continue") {
                        if !apiKey.isEmpty { model.saveAPIKey(apiKey) }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasAPIKey && apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
        }
        .frame(width: 560, height: 620)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "dog.fill").font(.system(size: 34))
            VStack(alignment: .leading) {
                Text("Welcome to JakeListen").font(.title2).bold()
                Text("Let's get you set up — about two minutes.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var tutorial: some View {
        VStack(alignment: .leading, spacing: 8) {
            step(1, "Click the blue button above to open **Google AI Studio** in your browser.")
            step(2, "Sign in with your Google account (any Gmail works).")
            step(3, "Click **Create API key**. If asked, accept the terms.")
            step(4, "Choose **Create API key in a new project** (simplest), or pick an existing Google Cloud project.")
            step(5, "Your key appears — click **Copy**.")
            step(6, "Come back here and paste it into the box below.")
            Divider().padding(.vertical, 4)
            Text("Cost: Gemini has a **free tier** that's plenty for personal call summaries. If you ever need higher limits, you can enable billing on the Google Cloud project tied to your key — but you don't need to pay to start.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Keep your key private — anyone with it can use your quota.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .padding(.top, 6)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).").bold().frame(width: 20, alignment: .trailing)
            Text(.init(text)) // markdown
        }
    }

    private func groupBox<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        } label: {
            Text(title).font(.headline)
        }
    }
}
