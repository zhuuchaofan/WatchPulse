import Charts
import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// 单项指标的历史趋势。
struct MetricTrendView: View {
    let viewModel: MetricTrendViewModel

    var body: some View {
        List {
            if viewModel.dataOrigin.isSimulated {
                DemoModeBanner()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                Picker("时间范围", selection: periodBinding) {
                    ForEach(TrendPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("trend.periodPicker")
            }

            if let explanation = viewModel.kind.explanation {
                Section {
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("trend.explanation")
                }
            }

            LoadStateView(state: viewModel.state, retry: { await viewModel.load() }) { trend in
                trendContent(trend)
            }
        }
        .navigationTitle(viewModel.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if viewModel.state == .idle {
                await viewModel.load()
            }
        }
        .refreshable { await viewModel.load() }
    }

    private var periodBinding: Binding<TrendPeriod> {
        Binding(
            get: { viewModel.period },
            set: { period in Task { await viewModel.select(period) } }
        )
    }

    @ViewBuilder
    private func trendContent(_ trend: MetricTrend) -> some View {
        Section(trend.kind.trendCaption) {
            TrendChart(trend: trend)
                .frame(height: 220)
                .padding(.vertical, 8)
                .accessibilityIdentifier("trend.chart")

            if let statistics = trend.statistics {
                StatisticsRow(kind: trend.kind, statistics: statistics)
            }
        }

        Section("每日明细") {
            ForEach(Array(trend.points.reversed().prefix(31))) { point in
                LabeledContent {
                    Text(trend.kind.formattedValueWithUnit(point.value))
                        .monospacedDigit()
                } label: {
                    Text(point.date.formatted(.dateTime.month().day().weekday()))
                }
            }
        }
    }
}

private struct TrendChart: View {
    let trend: MetricTrend

    var body: some View {
        Chart {
            ForEach(trend.points) { point in
                if trend.kind.aggregation == .discrete {
                    if let minimum = point.minimum, let maximum = point.maximum, minimum < maximum {
                        RuleMark(
                            x: .value("日期", point.date, unit: .day),
                            yStart: .value("最低", minimum),
                            yEnd: .value("最高", maximum)
                        )
                        .foregroundStyle(tint.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 6, lineCap: .round))
                    }
                    LineMark(
                        x: .value("日期", point.date, unit: .day),
                        y: .value(trend.kind.trendCaption, point.value)
                    )
                    .foregroundStyle(tint)
                    PointMark(
                        x: .value("日期", point.date, unit: .day),
                        y: .value(trend.kind.trendCaption, point.value)
                    )
                    .foregroundStyle(tint)
                    .symbolSize(20)
                } else {
                    BarMark(
                        x: .value("日期", point.date, unit: .day),
                        y: .value(trend.kind.trendCaption, point.value)
                    )
                    .foregroundStyle(tint.gradient)
                }
            }

            if let average = trend.statistics?.average {
                RuleMark(y: .value("平均", average))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartYAxisLabel(trend.kind.unitLabel)
    }

    private var tint: Color {
        switch trend.kind {
        case .heartRate, .restingHeartRate: return .red
        case .heartRateVariability: return .pink
        case .stepCount: return .orange
        case .activeEnergy: return .green
        case .sleep: return .indigo
        }
    }
}

private struct StatisticsRow: View {
    let kind: HealthMetricKind
    let statistics: MetricTrendStatistics

    var body: some View {
        HStack {
            switch kind.aggregation {
            case .discrete:
                item("平均", statistics.average)
                item("最低", statistics.minimum)
                item("最高", statistics.maximum)
            case .cumulative:
                item("日均", statistics.average)
                item("合计", statistics.total)
                item("最高", statistics.maximum)
            case .sleep:
                item("平均", statistics.average)
                item("最短", statistics.minimum)
                item("最长", statistics.maximum)
            }
        }
    }

    private func item(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(kind.formattedValueWithUnit(value))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("步数") {
    NavigationStack {
        MetricTrendView(viewModel: MetricTrendViewModel(kind: .stepCount, service: MockHealthDataService.demo()))
    }
}

#Preview("心率") {
    NavigationStack {
        MetricTrendView(viewModel: MetricTrendViewModel(kind: .heartRate, service: MockHealthDataService.demo()))
    }
}

#Preview("无数据") {
    NavigationStack {
        MetricTrendView(viewModel: MetricTrendViewModel(kind: .sleep, service: MockHealthDataService()))
    }
}
