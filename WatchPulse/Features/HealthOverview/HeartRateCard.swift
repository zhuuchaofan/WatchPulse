import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// 展示一条心率记录：数值、单位、采样时间、来源。
struct HeartRateCard: View {
    let sample: HeartRateSample

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("最新心率", systemImage: "heart.fill")
                .font(.headline)
                .foregroundStyle(.red)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(sample.beatsPerMinute, format: .number.precision(.fractionLength(0)))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("次/分")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Divider()

            VStack(spacing: 10) {
                LabeledContent("单位", value: "\(sample.unit)（BPM）")
                LabeledContent("采样时间", value: sample.startDate.formatted(date: .abbreviated, time: .standard))
                if !sample.isInstantaneous {
                    LabeledContent("结束时间", value: sample.endDate.formatted(date: .abbreviated, time: .standard))
                }
                LabeledContent("距今", value: sample.endDate.formatted(.relative(presentation: .named)))
                LabeledContent("来源", value: sample.source.name)
                if !sample.source.isAppleWatch {
                    Label("非 Apple Watch 记录（没有 Apple Watch 心率）", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let deviceDescription {
                    LabeledContent("设备", value: deviceDescription)
                }
                LabeledContent("来源标识", value: sample.source.bundleIdentifier)
            }
            .font(.subheadline)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var deviceDescription: String? {
        let parts = [sample.source.deviceName, sample.source.deviceModel, sample.source.productType]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        var unique: [String] = []
        for part in parts where !unique.contains(part) {
            unique.append(part)
        }
        return unique.isEmpty ? nil : unique.joined(separator: " · ")
    }
}

#Preview {
    HeartRateCard(sample: .previewSample())
        .padding()
        .background(Color(.systemGroupedBackground))
}
