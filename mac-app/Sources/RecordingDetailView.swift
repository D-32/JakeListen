// RecordingDetailView — the right-hand pane. While recording it shows the live
// timer + the two visualisers; otherwise it shows the selected past recording's
// transcript, summary, and the actions for it (Transcribe / Retry / Reveal / Delete).

import SwiftUI
import AppKit

struct RecordingDetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.isRecording {
            LiveRecordingView(recorder: model.recorder) { model.stopRecording() }
        } else if let rec = model.selected {
            PastRecordingView(model: model, rec: rec)
        } else {
            EmptyStateView { Task { await model.startRecording() } }
        }
    }
}

// MARK: - Live recording

private struct LiveRecordingView: View {
    @ObservedObject var recorder: AudioRecorder
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            VStack(spacing: 4) {
                Text(timeString(recorder.elapsed))
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Label("Recording", systemImage: "record.circle")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating)
            }

            VStack(spacing: 18) {
                VisualizerView(title: "You (microphone)", systemImage: "mic.fill",
                               level: recorder.micLevel, color: .green)
                VisualizerView(title: "Meeting (system audio)", systemImage: "person.2.wave.2.fill",
                               level: recorder.systemLevel, color: .blue)
            }
            .frame(maxWidth: 540)

            Button(action: onStop) {
                Label("Stop & Transcribe", systemImage: "stop.fill").padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)

            Text("Both meters should move — your voice on top, the meeting below.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Past recording

private struct PastRecordingView: View {
    @ObservedObject var model: AppModel
    let rec: Recording

    private var status: RecordingStatus { model.status(for: rec) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                switch status {
                case .transcribing:
                    infoBox {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Transcribing… this can take a few minutes for a long meeting.")
                        }
                    }
                case .failed:
                    infoBox(tint: .red) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Transcription failed", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red).font(.headline)
                            Text(rec.lastError ?? "Something went wrong.")
                                .foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                case .notTranscribed:
                    infoBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Not transcribed yet.").font(.headline)
                            Text(model.settings.hasAPIKey
                                 ? "The audio is saved. Transcribe it whenever you're ready."
                                 : "Add your Gemini API key in Settings, then transcribe.")
                                .foregroundStyle(.secondary)
                        }
                    }
                case .done:
                    if let summary = rec.summary, !summary.isEmpty {
                        section("Summary", systemImage: "sparkles", copyText: summary) {
                            Text(summary).textSelection(.enabled).lineSpacing(2)
                        }
                    }
                    section("Transcript", systemImage: "text.alignleft", copyText: rec.transcript) {
                        Text(rec.transcript ?? "")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .lineSpacing(3)
                    }
                case .recording:
                    EmptyView()
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(rec.title).font(.title2.weight(.semibold))
            HStack(spacing: 10) {
                StatusBadge(status: status)
                Text("· \(rec.durationText)").foregroundStyle(.secondary)
                Spacer()
                actions
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch status {
        case .failed:
            Button { model.transcribe(rec) } label: { Label("Retry", systemImage: "arrow.clockwise") }
        case .notTranscribed:
            Button { model.transcribe(rec) } label: { Label("Transcribe", systemImage: "text.badge.checkmark") }
                .buttonStyle(.borderedProminent)
        case .done:
            Button { model.transcribe(rec) } label: { Label("Re-transcribe", systemImage: "arrow.clockwise") }
        case .transcribing, .recording:
            EmptyView()
        }
        Menu {
            Button { model.revealInFinder(rec) } label: { Label("Reveal in Finder", systemImage: "folder") }
            Divider()
            Button(role: .destructive) { model.delete(rec) } label: { Label("Delete", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func section<Content: View>(_ title: String, systemImage: String,
                                        copyText: String? = nil,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let copyText, !copyText.isEmpty {
                    CopyButton(text: copyText)
                }
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func infoBox<Content: View>(tint: Color = .secondary,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Bits

/// A compact "Copy" button that flips to "Copied" for a moment after tapping.
struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation { copied = false }
            }
        } label: {
            Label(copied ? "Copied" : "Copy",
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption.weight(.medium))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(copied ? .green : .secondary)
        .help("Copy to clipboard")
    }
}

struct StatusBadge: View {
    let status: RecordingStatus
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(status.label).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
    }
    private var color: Color {
        switch status {
        case .recording:      return .red
        case .transcribing:   return .orange
        case .done:           return .green
        case .failed:         return .red
        case .notTranscribed: return .secondary
        }
    }
}

private struct EmptyStateView: View {
    let onRecord: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56)).foregroundStyle(.tint)
            Text("Ready when you are").font(.title2.weight(.semibold))
            Text("Hit Record to capture your first meeting —\nyour mic and the participants, both at once.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(action: onRecord) {
                Label("Record", systemImage: "record.circle").padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

func timeString(_ t: TimeInterval) -> String {
    let s = Int(t)
    return String(format: "%02d:%02d", s / 60, s % 60)
}
