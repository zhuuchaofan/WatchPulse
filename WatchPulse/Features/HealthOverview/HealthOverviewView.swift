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
                .background(Color(.systemGroupedBackground))
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
                .buttonStyle(.borderedProminent)
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
                    .buttonStyle(.borderedProminent)
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
                .buttonStyle(.borderedProminent)
            }

        case .loaded(let snapshot):
            ScrollView {
                VStack(spacing: 12) {
                    if viewModel.dataOrigin.isSimulated {
                        DemoModeBanner()
                    }
                    TodayHeroCard(status: TodayStatus.make(from: snapshot), onOpenTraining: onOpenTraining)

                    NavigationLink(value: HealthMetricKind.sleep) {
                        sleepCard(snapshot.card(for: .sleep))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today.sleep")

                    NavigationLink(value: HealthMetricKind.restingHeartRate) {
                        bodyCard(snapshot)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today.body")

                    NavigationLink(value: HealthMetricKind.stepCount) {
                        activityCard(snapshot)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today.activity")

                    if snapshot.cards.contains(where: { $0.baseline != nil }) {
                        // “平时水平”首次出现，在此用一句话解释。
                        Text(BaselineComparison.baselineExplanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("dashboard.baselineExplanation")
                    }

                    NavigationLink(value: AllMetricsRoute()) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("全部指标").font(.headline)
                                Text("最新心率、各项指标与趋势").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today.allMetrics")

                    lastCheckedFooter
                }
                .padding()
            }
            .refreshable { await viewModel.load() }
        }
    }

    // MARK: - 次级卡片

    private func sleepCard(_ card: MetricCardModel?) -> some View {
        TodayCard(title: "睡眠", systemImage: "bed.double.fill", tint: .indigo) {
            switch card?.status {
            case .value(let summary)?:
                let text = Self.sleepText(summary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(text.value).font(.title.weight(.bold)).monospacedDigit()
                    Text(text.note).font(.footnote).foregroundStyle(.secondary)
                }
            case .failed?:
                Text("暂时读不到睡眠记录").font(.subheadline).foregroundStyle(.orange)
            case .noData?, nil:
                Text("昨晚没有睡眠记录").font(.subheadline).foregroundStyle(.secondary)
                Text("睡觉时佩戴 Apple Watch，就能在这里看到。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func bodyCard(_ snapshot: HealthDashboardSnapshot) -> some View {
        TodayCard(title: "身体状态", systemImage: "heart.fill", tint: .red) {
            HStack(alignment: .top, spacing: 16) {
                TodayMetricColumn(kind: .restingHeartRate, card: snapshot.card(for: .restingHeartRate))
                TodayMetricColumn(kind: .heartRateVariability, card: snapshot.card(for: .heartRateVariability))
            }
        }
    }

    private func activityCard(_ snapshot: HealthDashboardSnapshot) -> some View {
        TodayCard(title: "今天的活动", systemImage: "figure.walk", tint: .orange) {
            HStack(alignment: .top, spacing: 16) {
                TodayMetricColumn(kind: .stepCount, card: snapshot.card(for: .stepCount))
                TodayMetricColumn(kind: .activeEnergy, card: snapshot.card(for: .activeEnergy))
            }
        }
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

/// 今日状态：结论（大字）+ 原因 + 下一步。不打分，只和自己的平时比较。
private struct TodayHeroCard: View {
    let status: TodayStatus
    let onOpenTraining: () -> Void

    private var tint: Color {
        switch status.level {
        case .steady: return .green
        case .changed: return .blue
        case .learning, .limited: return .gray
        }
    }

    private var symbol: String {
        switch status.level {
        case .steady: return "checkmark.circle.fill"
        case .changed: return "chart.line.uptrend.xyaxis"
        case .learning: return "clock.fill"
        case .limited: return "applewatch"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(Date.now, format: .dateTime.month().day().weekday(.wide))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            Text(status.headline)
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("today.headline")
            Text(status.reason)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("today.reason")
            actionButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.hero")
    }

    @ViewBuilder
    private var actionButton: some View {
        switch status.action {
        case .openTrend(let kind):
            NavigationLink(value: kind) { actionLabel }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .accessibilityIdentifier("today.action")
        case .openTraining:
            Button(action: onOpenTraining) { actionLabel }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .accessibilityIdentifier("today.action")
        }
    }

    private var actionLabel: some View {
        HStack(spacing: 6) {
            Text(status.action.title)
            Image(systemName: "chevron.right").font(.caption.weight(.bold))
        }
        .font(.subheadline.weight(.semibold))
    }
}

/// 次级卡片外框：标题行 + 内容 + 右侧箭头，整张卡片是一个无障碍元素。
private struct TodayCard<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    let content: Content

    init(title: String, systemImage: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

/// 卡片里的一项指标：名称、数值与单位，必要时附“比平时高 / 低”。
private struct TodayMetricColumn: View {
    let kind: HealthMetricKind
    let card: MetricCardModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kind.title).font(.caption).foregroundStyle(.secondary)
            switch card?.status {
            case .value(let summary)?:
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(kind.formattedValue(summary.value))
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                    Text(kind.unitLabel).font(.caption).foregroundStyle(.secondary)
                }
                if let baseline = card?.baseline {
                    Text(baseline.plainShortText).font(.caption).foregroundStyle(.secondary)
                } else if kind.aggregation == .cumulative {
                    Text("今日累计").font(.caption).foregroundStyle(.secondary)
                }
            case .failed?:
                Text("暂时读不到").font(.subheadline).foregroundStyle(.orange)
            case .noData?, nil:
                Text("暂无记录").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .background(Color(.systemGroupedBackground))
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
