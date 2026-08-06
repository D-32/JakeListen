// UpdateSheet — the "there's a newer JakeListen" popup. One prominent button
// does the whole thing: download, verify, swap, relaunch.

import SwiftUI

struct UpdateSheet: View {
    @ObservedObject var updater: UpdateModel
    let info: UpdateInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 28)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("JakeListen \(info.version.description) is available")
                        .font(.headline)
                    Text("You have \(updater.currentVersion.description).")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }

            if !info.notes.isEmpty {
                ScrollView {
                    Text(info.notes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(12)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

            switch updater.phase {
            case .failed(let message):
                VStack(alignment: .leading, spacing: 8) {
                    Label("Update failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.red)
                    Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            case .idle:
                EmptyView()
            default:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(updater.phase.label).font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Download Manually") { NSWorkspace.shared.open(UpdateConfig.releasesPage) }
                    .buttonStyle(.link)
                Spacer()
                Button("Skip This Version") { updater.skip(info) }
                Button("Later") { updater.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isRetry ? "Try Again" : "Update & Restart") { updater.install(info) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .disabled(updater.phase.isBusy)
        }
        .padding(22)
        .frame(width: 480)
        .interactiveDismissDisabled(updater.phase.isBusy)
    }

    private var isRetry: Bool {
        if case .failed = updater.phase { return true }
        return false
    }
}
