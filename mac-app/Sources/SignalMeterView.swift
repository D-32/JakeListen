// SignalMeterView — the live input waveform shown while recording.
//
// A row of bars driven by AudioMeter.history (a scrolling level history) plus a
// one-line signal read-out. When the bars are dancing you can see the mic is
// being heard; when they flatline the view turns amber and says so, so you know
// straight away that nothing is actually being captured.

import SwiftUI

struct SignalMeterView: View {
    @ObservedObject var meter: AudioMeter

    private var tint: Color {
        if meter.error != nil || meter.noSignal { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            waveform
            statusLine
        }
        .animation(.easeOut(duration: 0.12), value: meter.noSignal)
    }

    // Centre-anchored bars so silence reads as a flat line and sound fans out.
    private var waveform: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(meter.history.enumerated()), id: \.offset) { _, v in
                Capsule()
                    .fill(tint.opacity(0.35 + 0.65 * Double(v)))
                    .frame(width: 3, height: max(3, CGFloat(v) * 30))
            }
        }
        .frame(height: 30, alignment: .center)
        .animation(.linear(duration: 0.08), value: meter.history)
        .accessibilityLabel("Microphone input level")
        .accessibilityValue(meter.noSignal ? "No signal" : "Receiving audio")
    }

    @ViewBuilder
    private var statusLine: some View {
        if let error = meter.error {
            label("exclamationmark.triangle.fill", error)
        } else if meter.noSignal {
            label("waveform.slash", "No input detected — check your microphone")
        } else {
            label("waveform", "Receiving audio")
        }
    }

    private func label(_ systemImage: String, _ text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(tint)
            .symbolRenderingMode(.hierarchical)
    }
}
