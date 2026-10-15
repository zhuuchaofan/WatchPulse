import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// 总览页中单项指标的小卡片。
struct MetricSummaryCard: View {
    let card: MetricCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(card.kind.title, systemImage: card.kind.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            switch card.status {
            case .value(let summary):
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(card.kind.formattedValue(summary.value))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                    if card.kind != .sleep {
                        Text(card.kind.unitLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(caption(for: summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let baseline = card.baseline {
                    Text(baseline.shortText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(baseline.sufficiency == .sufficient ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

            case .noData:
                Text("—")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("暂无数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .failed(let error):
                Label("读取失败", systemImage: "exclamationmark.triangle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch card.kind {
        case .heartRate, .restingHeartRate: return .red
        case .heartRateVariability: return .pink
        case .stepCount: return .orange
        case .activeEnergy: return .green
        case .sleep: return .indigo
        }
    }

    private func caption(for summary: MetricSummaryValue) -> String {
        if let night = summary.sleepNight {
            let recency = SleepAggregator.recencyLabel(for: night, today: .now)
            if night.isInBedOnly {
                return "\(recency) · 仅有卧床记录"
            }
            let deep = night.stageDurations[.deep] ?? 0
            return deep > 0 ? "\(recency) · 深度睡眠 \(MetricFormatting.duration(seconds: deep))" : recency
        }
        switch card.kind.aggregation {
        case .cumulative:
            return card.kind.summaryCaption
        case .discrete, .sleep:
            return "\(card.kind.summaryCaption) · \(summary.date.formatted(.relative(presentation: .named)))"
        }
    }
}

#Preview {
    let data = SimulatedHealthData(now: .now)
    return LazyVGrid(columns: [GridItem(), GridItem()]) {
        ForEach(HealthDashboardSnapshot.cardKinds, id: \.self) { kind in
            MetricSummaryCard(card: MetricCardModel(kind: kind, status: .value(data.summary(for: kind))))
        }
        MetricSummaryCard(card: MetricCardModel(kind: .stepCount, status: .noData))
        MetricSummaryCard(card: MetricCardModel(kind: .sleep, status: .failed(.protectedDataUnavailable)))
    }
    .padding()
    .background(Color(.systemGroupedBackground))
}
