import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// 运动详情中的“运动后反馈”（v0.3 T3）：与自己之前的可比同类运动比较，每条结论附对比对象与样本数。
struct WorkoutFeedbackSection: View {
    let viewModel: WorkoutFeedbackViewModel

    var body: some View {
        Section {
            switch viewModel.state {
            case .loaded(let result):
                content(result)
            case .noData:
                Text("这次运动不在已读取的运动记录范围内，暂时无法与过去比较。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .idle, .loading:
                HStack {
                    ProgressView()
                    Text("正在读取过去的同类运动…").font(.footnote).foregroundStyle(.secondary)
                }
            default:
                LoadStateView(
                    state: viewModel.state,
                    noDataTitle: "无法比较",
                    noDataMessage: "",
                    retry: { await viewModel.load() }
                ) { _ in EmptyView() }
            }
        } header: {
            Text("运动后反馈")
        } footer: {
            Text(WorkoutFeedbackPresentation.disclaimer)
        }
        // 不在 Section 上设置 accessibilityIdentifier：它会覆盖每一行自己的标识。
        .task {
            if viewModel.state == .idle {
                await viewModel.load()
            }
        }
    }

    @ViewBuilder
    private func content(_ result: WorkoutFeedbackResult) -> some View {
        let feedback = result.feedback
        Text(WorkoutFeedbackPresentation.headline(feedback))
            .font(.footnote)
            .accessibilityIdentifier("workoutDetail.feedback.headline")
        if result.isMergedDuplicate {
            Text("这条记录与另一条确认重复，反馈按合并后的记录计算。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        ForEach(feedback.metrics, id: \.metric) { item in
            MetricFeedbackRow(item: item, activity: feedback.activity)
        }

        if !feedback.zones.rows.isEmpty {
            ZoneFeedbackRows(zones: feedback.zones)
        } else {
            Text(WorkoutFeedbackPresentation.zoneSummary(feedback.zones))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let line = WorkoutFeedbackPresentation.exclusionLine(feedback) {
            Text(line)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("workoutDetail.feedback.exclusions")
        }
        ForEach(WorkoutFeedbackPresentation.caveatLines(feedback), id: \.self) { line in
            Text(line).font(.caption).foregroundStyle(.secondary)
        }
        if result.mayMissOlderWorkouts {
            Text("运动记录较多，只读取了最近的一部分，时间窗内更早的运动可能未参与比较。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MetricFeedbackRow: View {
    let item: WorkoutMetricFeedback
    let activity: WorkoutActivityKind

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(WorkoutFeedbackPresentation.title(of: item.metric, activity: activity))
                Spacer()
                Text(WorkoutFeedbackPresentation.format(item.currentValue, metric: item.metric, activity: activity))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
            }
            Text(WorkoutFeedbackPresentation.comparison(item, activity: activity))
                .font(.caption)
                .foregroundStyle(isCompared ? Color.primary : Color.secondary)
            if case .compared(_, _, _, _, let baseline) = item.outcome {
                Text("对比对象：\(Self.range(baseline)) 的 \(baseline.sampleCount) 次运动")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workoutDetail.feedback.metric")
    }

    private var isCompared: Bool {
        if case .compared = item.outcome { return true }
        return false
    }

    static func range(_ baseline: WorkoutFeedbackBaseline) -> String {
        let style = Date.FormatStyle.dateTime.month().day()
        let first = baseline.earliestStart.formatted(style)
        let last = baseline.latestStart.formatted(style)
        return first == last ? first : "\(first)–\(last)"
    }
}

private struct ZoneFeedbackRows: View {
    let zones: WorkoutZoneFeedback

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("个人心率区间分布").font(.subheadline)
            ForEach(zones.rows.reversed(), id: \.zone) { row in
                HStack {
                    Text(WorkoutFeedbackPresentation.zoneTitle(row.zone)).font(.caption)
                    Spacer()
                    Text(WorkoutFeedbackPresentation.zoneShare(row))
                        .font(.caption)
                        .monospacedDigit()
                }
            }
            Text(WorkoutFeedbackPresentation.zoneSummary(zones))
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let basis = zones.basis {
                Text(basis.title).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
