// VisualizerView — a live scrolling level meter for one audio source, so you can
// see at a glance that both your mic and the meeting audio are being picked up.

import SwiftUI

struct VisualizerView: View {
    let title: String
    let systemImage: String
    let level: Float          // 0…1, updated ~30×/s while recording
    let color: Color
    var active: Bool = true

    private let count = 52
    @State private var samples: [CGFloat] = Array(repeating: 0, count: 52)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(active ? color : .secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(active && level > 0.04 ? color : Color.secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }

            GeometryReader { geo in
                let barW = geo.size.width / CGFloat(count)
                let midY = geo.size.height / 2
                HStack(alignment: .center, spacing: barW * 0.34) {
                    ForEach(0..<count, id: \.self) { i in
                        Capsule()
                            .fill(color.opacity(active ? 0.85 : 0.3))
                            .frame(width: barW * 0.66,
                                   height: max(3, samples[i] * (midY * 1.9)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 72)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
        .onChange(of: level) { _, newValue in
            samples.append(CGFloat(max(0, min(1, newValue))))
            if samples.count > count { samples.removeFirst(samples.count - count) }
        }
        .onChange(of: active) { _, isActive in
            if !isActive { samples = Array(repeating: 0, count: count) }
        }
    }
}
