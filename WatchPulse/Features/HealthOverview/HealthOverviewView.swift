import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// 「今日」首页：顶部一张状态卡（结论 + 原因 + 下一步），下面是睡眠、身体状态、活动量三张次级卡片。
/// 最新心率与全部指标放在二级页面「全部指标」，原有功能都保留。
struct HealthOverviewView: View {
    let viewModel: HealthOverviewViewModel
    /// 用于创建趋势页的 ViewModel。
    let service: any HealthDataService
    /// 状态卡上的“看看本周训练”：由根视图切换到运动页。
    var onOpenTraining: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background.ignoresSafeArea())
                .navigationTitle("今日")
                .navigationDestination(for: HealthMetricKind.self) { kind in
                    MetricTrendScreen(kind: kind, service: service)
                }
                .navigationDestination(for: AllMetricsRoute.self) { _ in
                    AllMetricsView(viewModel: viewModel)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            Task { await viewModel.load() }
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .disabled(viewModel.isLoading)
                    }
                }
        }
        .task {
            await viewModel.load()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // 从「设置」或「健康」App 修改权限后返回时重新读取。
            if newPhase == .active, viewModel.state != .idle {
                Task { await viewModel.load() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView("正在读取今天的状态…")

        case .healthDataUnavailable:
            ContentUnavailableView(
                "这台设备用不了“健康”",
                systemImage: "heart.slash",
                description: Text("请在 iPhone 上使用 WatchPulse。")
            )

        case .needsAuthorization:
            ContentUnavailableView {
                Label("先连接“健康”", systemImage: "heart.text.square")
            } description: {
                Text("WatchPulse 会读取心率、睡眠、步数和运动记录，只在这台 iPhone 上显示，不会上传。用 Apple Watch 运动时，运动记录也会保存到“健康”。")
            } actions: {
                Button("允许读取健康数据") {
                    Task { await viewModel.requestAuthorizationAndLoad() }
                }
                .buttonStyle(.themePrimary)
                .accessibilityIdentifier("dashboard.authorize")
            }

        case .noData:
            ScrollView {
                if viewModel.dataOrigin.isSimulated {
                    DemoModeBanner().padding(.horizontal)
                }
                ContentUnavailableView {
                    Label("暂无可读取的健康数据", systemImage: "waveform.path.ecg")
                } description: {
                    Text(Self.noDataExplanation)
                } actions: {
                    Button("重新读取") {
                        Task { await viewModel.load() }
                    }
                    .buttonStyle(.themePrimary)
                    OpenSettingsButton()
                }
                lastCheckedFooter
            }
            .refreshable { await viewModel.load() }

        case .failed(let error):
            ContentUnavailableView {
                Label("暂时读不到数据", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.localizedDescription)
            } actions: {
                Button("重试") {
                    Task { await viewModel.load() }
                }
                .buttonStyle(.themePrimary)
            }

        case .loaded(let snapshot):
            ScrollView {
                VStack(spacing: Theme.cardSpacing) {
                    if viewModel.dataOrigin.isSimulated {
                        DemoModeBanner()
                    }
                    TodayHeroCard(status: TodayStatus.make(from: snapshot), snapshot: snapshot, onOpenTraining: onOpenTraining)

                    NavigationLink(value: HealthMetricKind.sleep) {
                        sleepCard(snapshot.card(for: .sleep))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today.sleep")

                    NavigationLink(value: HealthMetricKind.stepCount) {
                        activityCard(snapshot)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today.activity")

                    NavigationLink(value: AllMetricsRoute()) {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("全部指标").font(.headline).foregroundStyle(Theme.text)
                                Text(Self.allMetricsSubtitle(snapshot)).font(.footnote).foregroundStyle(Theme.secondaryText)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                        }
                        .cardStyle(padding: 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today.allMetrics")

                    lastCheckedFooter
                }
                .padding(.horizontal, Theme.gutter)
                .padding(.vertical, 8)
            }
            .refreshable { await viewModel.load() }
        }
    }

    static func allMetricsSubtitle(_ snapshot: HealthDashboardSnapshot) -> String {
        guard let sample = snapshot.latestHeartRate else { return "最新心率、趋势与每日明细" }
        let ago = sample.endDate.formatted(.relative(presentation: .named))
        return "最新心率 \(HealthMetricKind.heartRate.formattedValueWithUnit(sample.beatsPerMinute))（\(ago)）、趋势与每日明细"
    }

    // MARK: - 次级卡片

    private func sleepCard(_ card: MetricCardModel?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            switch card?.status {
            case .value(let summary)?:
                let text = Self.sleepText(summary)
                CardHeader(title: "睡眠", systemImage: "moon", trailing: summary.sleepNight.map(Self.sleepTimeRange))
                VStack(alignment: .leading, spacing: 2) {
                    MetricNumber(value: text.value, style: .title)
                    Text(text.note).font(.footnote).foregroundStyle(Theme.secondaryText)
                }
                if let night = summary.sleepNight, !night.isInBedOnly {
                    SleepStageBar(night: night)
                }
                if let source = summary.sleepNight?.primarySourceName {
                    Text("来自 \(source)").font(.footnote).foregroundStyle(Theme.secondaryText)
                }
            case .failed?:
                CardHeader(title: "睡眠", systemImage: "moon")
                Text("暂时读不到睡眠记录").font(.subheadline).foregroundStyle(Theme.notice)
            case .noData?, nil:
                CardHeader(title: "睡眠", systemImage: "moon")
                Text("昨晚没有睡眠记录").font(.subheadline).foregroundStyle(Theme.text)
                Text("睡觉时佩戴 Apple Watch，就能在这里看到。").font(.footnote).foregroundStyle(Theme.secondaryText)
            }
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    private func activityCard(_ snapshot: HealthDashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "今天的活动", systemImage: "figure.walk", trailing: "截至 \(Date.now.formatted(date: .omitted, time: .shortened))")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { activityColumns(snapshot) }
                VStack(alignment: .leading, spacing: 12) { activityColumns(snapshot) }
            }
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func activityColumns(_ snapshot: HealthDashboardSnapshot) -> some View {
        ActivityColumn(kind: .stepCount, card: snapshot.card(for: .stepCount))
        ActivityColumn(kind: .activeEnergy, card: snapshot.card(for: .activeEnergy))
    }

    static func sleepTimeRange(_ night: SleepNight) -> String {
        "\(night.start.formatted(date: .omitted, time: .shortened))–\(night.end.formatted(date: .omitted, time: .shortened))"
    }

    /// 睡眠时长与说明。有分夜数据时用“昨晚 / 前天”等说法，只有卧床记录时如实说明。
    static func sleepText(_ summary: MetricSummaryValue) -> (value: String, note: String) {
        guard let night = summary.sleepNight else {
            return (HealthMetricKind.sleep.formattedValue(summary.value), "昨晚")
        }
        let recency = SleepAggregator.recencyLabel(for: night, today: .now)
        let value = MetricFormatting.duration(seconds: night.primaryDuration)
        return (value, night.isInBedOnly ? "\(recency) · 仅有卧床记录" : recency)
    }

    @ViewBuilder
    private var lastCheckedFooter: some View {
        if let lastCheckedAt = viewModel.lastCheckedAt {
            Text("最近更新：\(lastCheckedAt.formatted(date: .omitted, time: .shortened))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// 系统不会告知读取权限是否被关闭，因此这里只列出可能原因，不下“被拒绝”的结论。
    static let noDataExplanation = """
    “健康”里还没有 WatchPulse 能读取的记录。可能的原因：
    • 还没有数据，比如刚开始佩戴 Apple Watch
    • 还没有允许 WatchPulse 读取，可以点“检查读取权限”看看
    出于隐私保护，iPhone 不会告诉 App 读取权限是否已关闭。
    """
}

// MARK: - 状态卡

/// 今日状态：时间范围 + 结论 + 最近 7 天与平时的数值 + 下一步。不打分，只和自己的平时比较，不判断差异大小。
private struct TodayHeroCard: View {
    let status: TodayStatus
    let snapshot: HealthDashboardSnapshot
    let onOpenTraining: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "heart")
                    .foregroundStyle(Theme.sage)
                    .accessibilityHidden(true)
                Text(periodText)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("today.period")
            }
            Text(status.headline)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("today.headline")

            NavigationLink(value: HealthMetricKind.restingHeartRate) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { tiles }
                    VStack(spacing: 12) { tiles }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("today.body")

            Text(status.reason)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("today.reason")
            actionButton
        }
        .cardStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.hero")
    }

    /// 例如“最近 7 天（10/9–10/15）对比之前 4 周”。
    private var periodText: String {
        guard let observation = status.observation else {
            return Date.now.formatted(.dateTime.month().day().weekday(.wide))
        }
        let last = observation.end.addingTimeInterval(-1)
        let range = "\(observation.start.formatted(.dateTime.month(.defaultDigits).day()))–\(last.formatted(.dateTime.month(.defaultDigits).day()))"
        return "最近 7 天（\(range)）对比之前 4 周"
    }

    @ViewBuilder
    private var tiles: some View {
        BodyMetricTile(kind: .restingHeartRate, card: snapshot.card(for: .restingHeartRate))
        BodyMetricTile(kind: .heartRateVariability, card: snapshot.card(for: .heartRateVariability))
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status.action {
        case .openTrend(let kind):
            NavigationLink(value: kind) { actionLabel }
                .buttonStyle(.themePrimary)
                .accessibilityIdentifier("today.action")
        case .openTraining:
            Button(action: onOpenTraining) { actionLabel }
                .buttonStyle(.themePrimary)
                .accessibilityIdentifier("today.action")
        }
    }

    private var actionLabel: some View {
        HStack(spacing: 6) {
            Text(status.action.title)
            Image(systemName: "chevron.right").font(.caption.weight(.bold))
        }
    }
}

/// 状态卡里的一项身体指标：平时水平够用时显示最近 7 天的典型值与平时值；否则显示最新值并说明还在积累。
private struct BodyMetricTile: View {
    let kind: HealthMetricKind
    let card: MetricCardModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kind.title).font(.footnote).foregroundStyle(Theme.secondaryText)
            if let baseline = card?.baseline, baseline.sufficiency == .sufficient,
               let recent = baseline.observationMedian, let usual = baseline.referenceMedian {
                MetricNumber(value: kind.formattedValue(recent), unit: kind.unitLabel, style: .title)
                Text("平时 \(kind.formattedValue(usual))").font(.footnote).foregroundStyle(Theme.secondaryText)
            } else {
                switch card?.status {
                case .value(let summary)?:
                    MetricNumber(value: kind.formattedValue(summary.value), unit: kind.unitLabel, style: .title)
                    Text(card?.baseline == nil ? "暂时没有平时水平" : "平时水平还在积累")
                        .font(.footnote).foregroundStyle(Theme.secondaryText)
                case .failed?:
                    Text("暂时读不到").font(.subheadline).foregroundStyle(Theme.notice)
                case .noData?, nil:
                    Text("暂无记录").font(.subheadline).foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .tile()
    }
}

/// 活动卡里的一项：名称与今日累计值。
private struct ActivityColumn: View {
    let kind: HealthMetricKind
    let card: MetricCardModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kind.title).font(.footnote).foregroundStyle(Theme.secondaryText)
            switch card?.status {
            case .value(let summary)?:
                MetricNumber(value: kind.formattedValue(summary.value), unit: kind.unitLabel.isEmpty ? nil : kind.unitLabel, style: .title2)
            case .failed?:
                Text("暂时读不到").font(.subheadline).foregroundStyle(Theme.notice)
            case .noData?, nil:
                Text("暂无记录").font(.subheadline).foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 睡眠分期条：深睡 / 核心 / 快速眼动 / 清醒。只有分期数据时显示；无障碍读出各段时长。
private struct SleepStageBar: View {
    let night: SleepNight

    private static let stages: [(SleepStage, String)] = [(.deep, "深睡"), (.core, "核心"), (.rem, "快速眼动"), (.awake, "清醒")]

    private var segments: [(name: String, duration: TimeInterval, color: Color)] {
        Self.stages.compactMap { stage, name in
            guard let duration = night.stageDurations[stage], duration > 0 else { return nil }
            return (name, duration, color(for: stage))
        }
    }

    private func color(for stage: SleepStage) -> Color {
        switch stage {
        case .deep: return Theme.sageText
        case .core: return Theme.sage
        case .rem: return Theme.sage.opacity(0.45)
        default: return Theme.line
        }
    }

    var body: some View {
        let segments = segments
        let total = segments.map(\.duration).reduce(0, +)
        if total > 0 {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        ForEach(segments, id: \.name) { segment in
                            segment.color
                                .frame(width: max(2, (proxy.size.width - CGFloat(segments.count - 1) * 2) * segment.duration / total))
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(Capsule())
                .accessibilityHidden(true)
                Text(segments.map { "\($0.name) \(MetricFormatting.duration(seconds: $0.duration))" }.joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

// MARK: - 二级页：全部指标

private struct AllMetricsRoute: Hashable {}

/// 最新心率（含数据详情）与全部指标卡片。读取 ViewModel 的当前数据，刷新后自动更新。
private struct AllMetricsView: View {
    let viewModel: HealthOverviewViewModel

    var body: some View {
        ScrollView {
            if let snapshot = viewModel.state.value {
                VStack(spacing: 12) {
                    heartRateSection(snapshot)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(snapshot.cards) { card in
                            NavigationLink(value: card.kind) {
                                MetricSummaryCard(card: card)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("metricCard.\(card.kind.rawValue)")
                        }
                    }
                }
                .padding()
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("全部指标")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.load() }
    }

    @ViewBuilder
    private func heartRateSection(_ snapshot: HealthDashboardSnapshot) -> some View {
        if let sample = snapshot.latestHeartRate {
            // 卡片内有可展开的“数据详情”，因此不整体作为链接；趋势入口在卡片底部。
            HeartRateCard(sample: sample)
                .accessibilityIdentifier("dashboard.heartRateCard")
        } else {
            NavigationLink(value: HealthMetricKind.heartRate) {
                MetricSummaryCard(card: MetricCardModel(
                    kind: .heartRate,
                    status: snapshot.heartRateError.map(MetricCardStatus.failed) ?? .noData
                ))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("dashboard.heartRateCard")
        }
    }
}

/// 持有趋势页 ViewModel 的容器，避免视图重建时重复创建 ViewModel。
struct MetricTrendScreen: View {
    @State private var viewModel: MetricTrendViewModel

    init(kind: HealthMetricKind, service: any HealthDataService) {
        _viewModel = State(initialValue: MetricTrendViewModel(kind: kind, service: service))
    }

    var body: some View {
        MetricTrendView(viewModel: viewModel)
    }
}

// MARK: - Previews（仅使用 MockHealthDataService，非真实数据）

#Preview("演示数据") {
    let service = MockHealthDataService.demo()
    return HealthOverviewView(viewModel: HealthOverviewViewModel(service: service), service: service)
}

#Preview("平时水平积累中") {
    let service = MockHealthDataService.demo()
    let data = SimulatedHealthData(now: .now)
    for kind in [HealthMetricKind.restingHeartRate, .heartRateVariability] {
        service.setTrend(.value(data.trend(for: kind, days: 10)), for: kind)
    }
    return HealthOverviewView(viewModel: HealthOverviewViewModel(service: service), service: service)
}

#Preview("加载中") {
    let service = MockHealthDataService(responseDelay: .seconds(3600))
    return HealthOverviewView(viewModel: HealthOverviewViewModel(service: service), service: service)
}

#Preview("需要授权") {
    let service = MockHealthDataService(authorizationStatus: .shouldRequest)
    return HealthOverviewView(viewModel: HealthOverviewViewModel(service: service), service: service)
}

#Preview("无数据") {
    let service = MockHealthDataService(fetchBehavior: .noData)
    return HealthOverviewView(viewModel: HealthOverviewViewModel(service: service), service: service)
}

#Preview("部分失败") {
    let service = MockHealthDataService(
        fetchBehavior: .sample(.previewSample()),
        summaries: [.sleep: .failure(.protectedDataUnavailable), .stepCount: .value(MetricSummaryValue(kind: .stepCount, value: 4_321, date: .now))]
    )
    return HealthOverviewView(viewModel: HealthOverviewViewModel(service: service), service: service)
}

#Preview("设备不支持") {
    let service = MockHealthDataService(isHealthDataAvailable: false)
    return HealthOverviewView(viewModel: HealthOverviewViewModel(service: service), service: service)
}
