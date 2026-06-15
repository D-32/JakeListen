// MainWindow — recordings list on the left, transcript + summary on the right,
// with a record/stop control in the toolbar.

import SwiftUI

struct MainWindow: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(PrefKey.showMenuBarItem) private var showMenuBarItem = true

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.showPostPrompt) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Post summary to Slack?").font(.headline)
                Text("Optional. Enter a channel, or skip.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("#channel", text: $model.postChannel)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onSubmit(post)
                HStack {
                    Spacer()
                    Button("Skip") { model.showPostPrompt = false }
                    Button("Post", action: post)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.postChannel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 320)
        }
    }

    private func post() {
        model.postSelectedToSlack(channel: model.postChannel)
        model.showPostPrompt = false
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(model.recordings, selection: $model.selectedID) { rec in
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.title).font(.body)
                Text(rec.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .tag(rec.id)
            .contextMenu {
                Button("Show in Finder") { model.reveal(rec) }
                Divider()
                Button("Delete (move to Trash)", role: .destructive) {
                    model.delete(rec)
                }
            }
        }
        .navigationTitle("Recordings")
        .overlay {
            if model.recordings.isEmpty {
                ContentUnavailableViewCompat(
                    title: "No recordings yet",
                    systemImage: "waveform",
                    description: "Press Record to capture your first call."
                )
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let rec = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(rec.title).font(.title2).bold()

                    if rec.hasSummary {
                        section("Summary", systemImage: "text.line.first.and.arrowtriangle.forward") {
                            Text(rec.summary)
                                .textSelection(.enabled)
                        }
                    }

                    if rec.hasTranscript && !rec.transcript.isEmpty {
                        section("Transcript", systemImage: "list.bullet") {
                            Text(rec.transcript)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    } else if !rec.hasSummary {
                        Text("No transcript — this recording had no detected speech.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        } else {
            ContentUnavailableViewCompat(
                title: "Select a recording",
                systemImage: "doc.text",
                description: "Pick a call from the list to read its transcript."
            )
        }
    }

    private func section<Content: View>(
        _ title: String, systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: model.toggle) {
                Label(recordLabel, systemImage: recordIcon)
            }
            .disabled(model.state == .processing || model.cliPath == nil)
            .tint(model.state == .recording ? .red : nil)
        }
        ToolbarItem(placement: .automatic) {
            if model.state == .recording {
                Text(model.elapsedText).monospacedDigit().foregroundStyle(.red)
            } else if model.state == .processing {
                ProgressView().controlSize(.small)
            }
        }
        ToolbarItem(placement: .automatic) {
            Text(model.status).font(.caption).foregroundStyle(.secondary)
        }
        ToolbarItem(placement: .automatic) {
            Button(role: .destructive) {
                if let rec = model.selected { model.delete(rec) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(model.selected == nil)
            .keyboardShortcut(.delete, modifiers: [])
            .help("Move the selected recording to the Trash")
        }
        ToolbarItem(placement: .automatic) {
            Button(action: model.refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        ToolbarItem(placement: .automatic) {
            Toggle(isOn: $showMenuBarItem) {
                Label("Menu-bar icon", systemImage: "menubar.rectangle")
            }
            .help("Show or hide the menu-bar icon")
        }
    }

    private var recordLabel: String {
        switch model.state {
        case .idle: return "Record"
        case .recording: return "Stop"
        case .processing: return "Processing"
        }
    }

    private var recordIcon: String {
        switch model.state {
        case .idle: return "record.circle"
        case .recording: return "stop.circle.fill"
        case .processing: return "hourglass"
        }
    }
}

/// Minimal stand-in for ContentUnavailableView so the app builds on macOS 14.0
/// (ContentUnavailableView is 14.0+, but we keep our own to avoid surprises and
/// keep the look consistent).
struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
