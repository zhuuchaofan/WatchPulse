import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// 最新心率卡片：只突出数值、多久前、哪块表测的；精确时间、手表型号与名称、记录方式收进“数据详情”（默认收起）。
/// 详情只展示看得懂的说明，不展示 HealthKit 单位字符串、Bundle ID 或硬件代码。
struct HeartRateCard: View {
    let sample: HeartRateSample

    /// 超过这个时长没有新心率时，把“多久前”标为橙色，提示数值已不新。
    private static let freshness: TimeInterval = 3_600

    @State private var showsDetails = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let isStale = context.date.timeIntervalSince(sample.endDate) > Self.freshness
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("最新心率", systemImage: "heart.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Spacer()
                    Text(MetricFormatting.ago(sample.endDate, now: context.date))
                        .font(.subheadline.weight(isStale ? .semibold : .regular))
                        .foregroundStyle(isStale ? Color.orange : Color.secondary)
                        .accessibilityIdentifier("heartRate.ago")
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(sample.beatsPerMinute, format: .number.precision(.fractionLength(0)))
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("次/分")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                Text("来自 \(sample.source.name) · \(MetricFormatting.friendlyDateTime(sample.endDate, now: context.date))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if !sample.source.isAppleWatch {
                    Label("非 Apple Watch 记录（没有 Apple Watch 心率）", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                DisclosureGroup("数据详情", isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        if sample.isInstantaneous {
                            LabeledContent("测量时间", value: sample.endDate.formatted(date: .abbreviated, time: .standard))
                        } else {
                            LabeledContent("测量时段", value: "\(sample.startDate.formatted(date: .abbreviated, time: .standard)) – \(sample.endDate.formatted(date: .omitted, time: .standard))")
                        }
                        if let model = sourceDescription.deviceModel {
                            LabeledContent(sample.source.isAppleWatch ? "手表型号" : "设备", value: model)
                        }
                        if let customName = sourceDescription.customName {
                            LabeledContent("手表名称", value: customName)
                            Text("这是你在 iPhone「Watch」App 里给这块手表起的名字，不代表手表品牌。")
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("记录方式", value: sourceDescription.recordedBy)
                    }
                    .font(.caption)
                    .padding(.top, 6)
                }
                .font(.subheadline)
                .tint(.secondary)
                .accessibilityIdentifier("heartRate.details")

                NavigationLink(value: HealthMetricKind.heartRate) {
                    HStack {
                        Label("查看心率趋势", systemImage: "chart.xyaxis.line")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .font(.subheadline)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("heartRate.trendLink")
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private var sourceDescription: HeartRateSourceDescription {
        HeartRateSourceDescription(source: sample.source)
    }
}

#Preview {
    HeartRateCard(sample: .previewSample(date: Date().addingTimeInterval(-600)))
        .padding()
        .background(Color(.systemGroupedBackground))
}
