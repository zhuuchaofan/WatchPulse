import Charts
import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// 分析页：把近期数据与你自己的历史比较（个人基线）、睡眠分期与作息规律。
/// 只描述数值变化与样本数，不做医学判断，也不合成“恢复分”。
struct InsightsView: View {
    let viewModel: HealthInsightsViewModel
    /// 用于进入原有的单项趋势页。
    let service: any HealthDataService

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("分析")
                .navigationDestination(for: HealthMetricKind.self) { kind in
                    MetricTrendScreen(kind: kind, service: service)
                }
        }
        .task {
            if viewModel.state == .idle {
                await viewModel.load()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, viewModel.state != .idle {
                Task { await viewModel.load() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .needsAuthorization:
            ContentUnavailableView {
                Label("需要读取健康数据", systemImage: "heart.text.square")
            } description: {
                Text("分析页使用静息心率、心率变异性与睡眠记录，只在本机计算，不会上传。")
            } actions: {
                Button("授权读取") {
                    Task { await viewModel.requestAuthorizationAndLoad() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("insights.authorize")
            }
        default:
            ScrollView {
                VStack(spacing: 16) {
                    if viewModel.dataOrigin.isSimulated {
                        DemoModeBanner()
                    }
                    LoadStateView(
                        state: viewModel.state,
                        noDataTitle: "暂无可分析的数据",
                        noDataMessage: "“健康”中没有可读取的静息心率、心率变异性或睡眠记录。可能尚无记录，也可能未授予读取权限：请在「设置 › 隐私与安全性 › 健康 › WatchPulse」中检查。",
                        retry: { await viewModel.load() }
                    ) { snapshot in
                        InsightsContent(viewModel: viewModel, snapshot: snapshot)
                    }
                }
                .padding()
            }
            .refreshable { await viewModel.load() }
        }
    }
}

private struct InsightsContent: View {
    let viewModel: HealthInsightsViewModel
    let snapshot: HealthInsightsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("你的近况（与自己的历史比较）")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            BaselineCard(kind: .restingHeartRate, state: snapshot.restingHeartRate)
                .accessibilityIdentifier("insights.restingHeartRate")
            BaselineCard(kind: .heartRateVariability, state: snapshot.heartRateVariability)
                .accessibilityIdentifier("insights.hrv")
            SleepInsightCard(state: snapshot.sleep)
                .accessibilityIdentifier("insights.sleep")

            InsightTrendCharts(viewModel: viewModel)

            DataBasisSection(snapshot: snapshot)
        }
    }
}

// MARK: - 基线卡片

private struct BaselineCard: View {
    let kind: HealthMetricKind
    let state: InsightCardState<BaselineComparison>

    var body: some View {
        NavigationLink(value: kind) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(kind.title, systemImage: kind.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(kind == .restingHeartRate ? .red : .pink)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                switch state {
                case .value(let comparison):
                    values(comparison)
                case .noData:
                    Text("暂无数据").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    Text("没有可读取的记录（可能未授权或尚无记录）。").font(.caption).foregroundStyle(.secondary)
                case .failed(let error):
                    Label("读取失败", systemImage: "exclamationmark.triangle")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func values(_ comparison: BaselineComparison) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            column("近 7 天", comparison.observationMedian)
            column("基线", comparison.referenceMedian)
            Spacer(minLength: 0)
            if let direction = comparison.direction {
                Image(systemName: icon(direction))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        Text(comparison.shortText)
            .font(.footnote.weight(.semibold))
        Text(comparison.detailText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if comparison.excludedDays > 0 {
            Text("已排除 \(comparison.excludedDays) 个超出合理范围的日值。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func column(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value.map(kind.formattedValue) ?? "--")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                Text(kind.unitLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func icon(_ direction: BaselineComparison.Direction) -> String {
        switch direction {
        case .up: return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat: return "arrow.right"
        }
    }
}

// MARK: - 睡眠

private struct SleepInsightCard: View {
    let state: InsightCardState<SleepInsight>

    var body: some View {
        NavigationLink(value: HealthMetricKind.sleep) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("睡眠", systemImage: "bed.double.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.indigo)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                switch state {
                case .value(let insight):
                    content(insight)
                case .noData:
                    Text("暂无数据").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    Text("近两周没有可读取的睡眠记录（可能未授权或尚无记录）。").font(.caption).foregroundStyle(.secondary)
                case .failed(let error):
                    Label("读取失败", systemImage: "exclamationmark.triangle")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func content(_ insight: SleepInsight) -> some View {
        if let night = insight.latestNight {
            HStack(alignment: .firstTextBaseline) {
                Text(MetricFormatting.duration(seconds: night.primaryDuration))
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                Text(SleepAggregator.recencyLabel(for: night, today: .now))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if insight.isInBedOnly {
                Label("只有卧床记录，无法推断实际睡着时长", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if insight.stages.isEmpty || !insight.hasStages {
                Text("这一晚没有睡眠分期（例如来自不记录分期的设备或 App）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if insight.hasStages {
                StageBar(stages: insight.stages)
                Text(insight.stages.map { "\($0.stage.insightTitle) \(MetricFormatting.duration(seconds: $0.duration))" }.joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let source = night.primarySourceName {
                Text("分期来源：\(source)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        Divider()
        if let regularity = insight.regularity {
            Text("近 \(regularity.nightCount) 晚：平均 \(MetricFormatting.duration(seconds: regularity.averageDuration))，入睡约 \(MetricFormatting.clockTime(minutesFromMidnight: regularity.averageBedtimeMinutes))（波动 ±\(Int(regularity.bedtimeDeviationMinutes.rounded())) 分钟），醒来约 \(MetricFormatting.clockTime(minutesFromMidnight: regularity.averageWakeMinutes))（波动 ±\(Int(regularity.wakeDeviationMinutes.rounded())) 分钟）。")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("作息规律需要近两周至少 \(SleepInsight.minimumNightsForRegularity) 晚记录（当前 \(insight.nightCount) 晚）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("睡眠分期比例因人而异，这里只做记录，不作为健康判断。")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}

private struct StageBar: View {
    let stages: [SleepInsight.StageShare]

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(stages) { share in
                    color(share.stage)
                        .frame(width: max(2, (proxy.size.width - CGFloat(stages.count) * 2) * share.fraction))
                }
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .accessibilityHidden(true)
    }

    private func color(_ stage: SleepStage) -> Color {
        switch stage {
        case .deep: return .indigo
        case .rem: return .cyan
        case .core: return .blue
        case .asleepUnspecified: return .teal
        case .awake: return .orange
        case .inBed: return .gray
        }
    }
}

// MARK: - 趋势

private struct InsightTrendCharts: View {
    @Bindable var viewModel: HealthInsightsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("趋势").font(.headline)
                Spacer()
                Picker("范围", selection: $viewModel.trendRange) {
                    ForEach(InsightTrendRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)
                .accessibilityIdentifier("insights.trendRange")
            }
            chart(.restingHeartRate, color: .red)
            chart(.heartRateVariability, color: .pink)
            chart(.sleep, color: .indigo)
            Text("缺测的日子不画点，不按 0 处理。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func chart(_ kind: HealthMetricKind, color: Color) -> some View {
        let days = viewModel.trendDays(for: kind)
        let valid = days.filter { $0.value != nil }
        VStack(alignment: .leading, spacing: 4) {
            Text("\(kind.title)（\(kind.unitLabel)） · \(valid.count)/\(days.count) 天有数据")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if valid.isEmpty {
                Text("暂无数据").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Chart(valid) { day in
                    LineMark(x: .value("日期", day.date, unit: .day), y: .value(kind.title, day.value ?? 0))
                        .foregroundStyle(color)
                    PointMark(x: .value("日期", day.date, unit: .day), y: .value(kind.title, day.value ?? 0))
                        .foregroundStyle(color)
                        .symbolSize(18)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXScale(domain: (days.first?.date ?? .now)...(days.last?.date ?? .now))
                .frame(height: 110)
            }
        }
    }
}

// MARK: - 数据依据

private struct DataBasisSection: View {
    let snapshot: HealthInsightsSnapshot

    var body: some View {
        DisclosureGroup("数据依据与来源") {
            VStack(alignment: .leading, spacing: 6) {
                Text("近 7 天：\(range(snapshot.windows.observation))（不含今天）")
                Text("基线：\(range(snapshot.windows.reference))，取有效日值的中位数")
                Text("需要基线期至少 \(BaselineComparison.minimumReferenceDays) 天、近期至少 \(BaselineComparison.minimumObservationDays) 天有数据，否则显示“积累中”。")
                Text("数据来自 Apple“健康”中的静息心率、心率变异性（SDNN）与睡眠记录，只在本机计算，不上传。")
                Text("更新于 \(snapshot.generatedAt.formatted(date: .omitted, time: .shortened))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .accessibilityIdentifier("insights.basis")
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))

        Text(BaselineComparison.disclaimer)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("insights.disclaimer")
    }

    private func range(_ interval: DateInterval) -> String {
        let last = interval.end.addingTimeInterval(-1)
        return "\(interval.start.formatted(.dateTime.month().day()))–\(last.formatted(.dateTime.month().day()))"
    }
}

#Preview("演示数据") {
    let service = MockHealthDataService.demo()
    return InsightsView(viewModel: HealthInsightsViewModel(service: service), service: service)
}

#Preview("数据不足") {
    let service = MockHealthDataService(trends: [
        .restingHeartRate: .value((1...6).map { MetricDataPoint(date: Calendar.current.date(byAdding: .day, value: -$0, to: .now)!, value: 60) }),
    ])
    return InsightsView(viewModel: HealthInsightsViewModel(service: service), service: service)
}

#Preview("无数据") {
    let service = MockHealthDataService()
    return InsightsView(viewModel: HealthInsightsViewModel(service: service), service: service)
}

#Preview("需要授权") {
    let service = MockHealthDataService.demo()
    service.authorizationStatus = .shouldRequest
    return InsightsView(viewModel: HealthInsightsViewModel(service: service), service: service)
}

#Preview("读取失败") {
    let service = MockHealthDataService(
        trends: [.restingHeartRate: .failure(.protectedDataUnavailable), .heartRateVariability: .failure(.protectedDataUnavailable)],
        sleepNights: .failure(.protectedDataUnavailable)
    )
    return InsightsView(viewModel: HealthInsightsViewModel(service: service), service: service)
}
