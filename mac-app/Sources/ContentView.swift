// ContentView — the main window: a sidebar of every recording (newest first, with
// a status badge so untranscribed / failed ones are always visible) and a detail
// pane. The Record/Stop button and Settings live in the toolbar.

import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var recorder: AudioRecorder

    init(model: AppModel) {
        self.model = model
        self.recorder = model.recorder
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 340)
        } detail: {
            RecordingDetailView(model: model)
                .frame(minWidth: 440, minHeight: 460)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { recordButton }
            ToolbarItem(placement: .automatic) {
                Button { model.showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView(settings: model.settings)
        }
        .alert(item: $model.alert) { a in
            if let deep = a.openSystemSettings, let url = URL(string: deep) {
                return Alert(title: Text(a.title), message: Text(a.message),
                             primaryButton: .default(Text("Open System Settings")) {
                                 NSWorkspace.shared.open(url)
                             },
                             secondaryButton: .cancel())
            }
            return Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
        .task {
            if !model.settings.hasAPIKey { model.showSettings = true }
        }
    }

    private var recordButton: some View {
        Button {
            model.toggleRecording()
        } label: {
            if model.isRecording {
                Label("Stop", systemImage: "stop.circle.fill")
            } else {
                Label("Record", systemImage: "record.circle")
            }
        }
        .tint(model.isRecording ? .red : .accentColor)
        .help(model.isRecording ? "Stop recording" : "Start recording")
    }

    private var sidebar: some View {
        List(selection: $model.selectedID) {
            Section("Recordings") {
                if model.recordings.isEmpty {
                    Text("No recordings yet")
                        .foregroundStyle(.secondary).font(.callout)
                        .padding(.vertical, 6)
                }
                ForEach(model.recordings) { rec in
                    RecordingRow(title: rec.title,
                                 durationText: rec.durationText,
                                 status: model.status(for: rec))
                        .tag(rec.id)
                        .contextMenu {
                            Button { model.revealInFinder(rec) } label: { Label("Reveal in Finder", systemImage: "folder") }
                            if model.status(for: rec) != .recording {
                                Button(role: .destructive) { model.delete(rec) } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { model.toggleRecording() } label: {
                Label(model.isRecording ? "Stop & Transcribe" : "New Recording",
                      systemImage: model.isRecording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .accentColor)
            .padding(10)
        }
    }
}

private struct RecordingRow: View {
    let title: String
    let durationText: String
    let status: RecordingStatus

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(status == .done ? durationText : status.label)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }

    private var dotColor: Color {
        switch status {
        case .recording:      return .red
        case .transcribing:   return .orange
        case .done:           return .green
        case .failed:         return .red
        case .notTranscribed: return .gray
        }
    }
}
