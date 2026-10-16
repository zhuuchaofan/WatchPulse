import Charts
import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// 进步页：最近 4 周趋势 → 训练完成情况 → 和过去的自己比 → 身体状态（与自己的平时比较）。
/// 只描述数值变化、对比对象与数据是否足够，不评价进步或退步，不做医学判断，也不合成“恢复分”。
struct InsightsView: View {
    let viewModel: HealthInsightsViewModel
    /// 用于进入原有的单项趋势页。
    let service: any HealthDataService
    let progressViewModel: WorkoutAnalysisViewModel
    /// 最近一次运动的对比与运动页、运动详情使用同一读取方式，三处结论一致。
    let workoutService: any WorkoutHistoryService
    let goalsViewModel: WorkoutGoalsViewModel
    /// 「设定目标」：由根视图切换到目标页。
    var onOpenGoals: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if viewModel.dataOrigin.isSimulated || progressViewModel.dataOrigin.isSimulated {
                        DemoModeBanner()
                    }
                    ProgressSection(
                        viewModel: progressViewModel,
                        workoutService: workoutService,
                        goalsViewModel: goalsViewModel,
                        onOpenGoals: onOpenGoals
                    )
                    bodySection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await loadAll() }
            .navigationTitle("进步")
            .navigationDestination(for: HealthMetricKind.self) { kind in
                MetricTrendScreen(kind: kind, service: service)
            }
        }
        .task {
            if viewModel.state == .idle { await viewModel.load() }
            // 新的运动随时可能写入“健康”：每次切到本页都重新读取（已有数据保留显示，不闪回加载中）。
            await progressViewModel.load()
            await goalsViewModel.load()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, viewModel.state != .idle {
                Task { await loadAll() }
            }
        }
    }

    private func loadAll() async {
        await viewModel.load()
        await progressViewModel.load()
        await goalsViewModel.load()
    }

    @ViewBuilder
    private var bodySection: some View {
        switch viewModel.state {
        case .needsAuthorization:
            VStack(alignment: .leading, spacing: 10) {
                Label("身体状态需要读取健康数据", systemImage: "heart.text.square")
                    .font(.headline)
                Text("这里会用到静息心率、心率变异性和睡眠记录，只在这台 iPhone 上计算，不会上传。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("允许读取") {
                    Task { await viewModel.requestAuthorizationAndLoad() }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("insights.authorize")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        default:
            LoadStateView(
                state: viewModel.state,
                noDataTitle: "暂无身体数据可分析",
                noDataMessage: "没有读到静息心率、心率变异性或睡眠记录。可能还没有数据，也可能还没有允许读取，可以检查读取权限。",
                retry: { await viewModel.load() }
            ) { snapshot in
                InsightsContent(viewModel: viewModel, snapshot: snapshot)
            }
        }
    }
}

// MARK: - 运动进步

/// 运动相关的三张卡：最近 4 周趋势、训练完成情况、可比运动分析。
private struct ProgressSection: View {
    let viewModel: WorkoutAnalysisViewModel
    let workoutService: any WorkoutHistoryService
    let goalsViewModel: WorkoutGoalsViewModel
    let onOpenGoals: () -> Void

    var body: some View {
        switch viewModel.state {
        case .loaded(let set):
            let summary = ProgressSummary.make(from: set, readLimit: viewModel.limit, now: .now)
            ProgressTrendCard(summary: summary)
            CompletionCard(viewModel: goalsViewModel, onOpenGoals: onOpenGoals)
            ComparableCard(workout: summary.latestWorkout, service: workoutService)
        case .noData:
            ProgressMessageCard(
                title: "最近 4 周还没有运动记录",
                message: "完成一次运动后，这里会显示每周的变化。如果“健康”里已经有运动，请检查是否允许 WatchPulse 读取。",
                systemImage: "figure.run"
            ) {
                OpenSettingsButton()
            }
            .accessibilityIdentifier("progress.empty")
            CompletionCard(viewModel: goalsViewModel, onOpenGoals: onOpenGoals)
        case .idle, .loading:
            ProgressView("正在读取运动记录…")
                .frame(maxWidth: .infinity, minHeight: 120)
        case .healthDataUnavailable:
            ProgressMessageCard(
                title: "这台设备用不了“健康”",
                message: "请在 iPhone 上使用 WatchPulse。",
                systemImage: "heart.slash"
            ) { EmptyView() }
        case .needsAuthorization:
            ProgressMessageCard(
                title: "先允许读取运动记录",
                message: "请先在「今日」页允许读取健康数据。",
                systemImage: "heart.text.square"
            ) { EmptyView() }
        case .failed:
            ProgressMessageCard(
                title: "暂时读不到运动记录",
                message: "目标设置不受影响，稍后再试一次。",
                systemImage: "exclamationmark.triangle"
            ) {
                Button("重试") { Task { await viewModel.load() } }
                    .buttonStyle(.borderedProminent)
            }
            .accessibilityIdentifier("progress.failed")
        }
    }
}

private struct ProgressMessageCard<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    let actions: Actions

    init(title: String, message: String, systemImage: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }
}

/// 最近 4 周每周运动次数。数据少于两周时只陈述事实，不说“上升 / 下降”。
private struct ProgressTrendCard: View {
    let summary: ProgressSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("最近 4 周")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            Text(summary.headline)
                .font(.title2.bold())
                .accessibilityIdentifier("progress.headline")
            Text(summary.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if summary.hasAnyWorkout {
                Chart(summary.weeks) { week in
                    BarMark(x: .value("周", week.label), y: .value("次数", week.workoutCount))
                        .foregroundStyle(week.isCurrentWeek ? Color.green : Color.green.opacity(0.45))
                        .annotation(position: .top) {
                            Text("\(week.workoutCount)").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartYScale(domain: 0...((summary.weeks.map(\.workoutCount).max() ?? 1) + 1))
                .chartYAxis(.hidden)
                .frame(height: 140)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary.chartDescription)
                .accessibilityIdentifier("progress.chart")

                if let week = summary.currentWeek {
                    Text("本周 \(week.workoutCount) 次 · 共 \(MetricFormatting.duration(seconds: week.totalDuration))，本周还没结束")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if summary.suspectedExcludedCount > 0 {
                Text("含 \(summary.suspectedExcludedCount) 条疑似重复的记录，已只计一次。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if summary.mayBeIncomplete {
                Text("运动记录较多，只读取了最近的一部分，较早的周可能偏低。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("progress.trend")
    }
}

/// 训练完成情况：每个未暂停目标本周的进度与近 4 周达成情况。目标由用户设定，这里不评价。
private struct CompletionCard: View {
    let viewModel: WorkoutGoalsViewModel
    let onOpenGoals: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("训练完成情况")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                Spacer()
                if !viewModel.goals.isEmpty {
                    Button("管理目标", action: onOpenGoals)
                        .font(.subheadline)
                }
            }
            if viewModel.goals.isEmpty {
                Text("还没有每周目标")
                    .font(.headline)
                Text("设一个每周想完成的运动次数、时长或距离，就能在这里看到每周的完成情况。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("设定目标", action: onOpenGoals)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("progress.setGoal")
            } else {
                ForEach(viewModel.items) { item in
                    GoalCompletionRow(item: item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("progress.completion")
    }
}

private struct GoalCompletionRow: View {
    let item: WorkoutGoalItem

    static func symbol(for outcome: WorkoutGoalWeekProgress.Outcome) -> String {
        switch outcome {
        case .achieved: return "checkmark.circle.fill"
        case .beforeGoalCreated: return "circle.dashed"
        case .inProgress, .notAchieved: return "circle"
        }
    }

    static func completionText(counted: [WorkoutGoalWeekProgress], hasWeeksBeforeGoal: Bool) -> String {
        let achieved = counted.filter(\.isAchieved).count
        let summary = "近 \(counted.count) 周有 \(achieved) 周达到目标"
        return hasWeeksBeforeGoal ? summary + "（设定前的周不计入）" : summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.goal.title).font(.headline)
            switch item.progress {
            case .active(let current, let previous)?:
                let metric = item.goal.metric
                Text("本周 \(metric.format(current.value)) / \(metric.format(current.target))")
                    .font(.subheadline)
                    .monospacedDigit()
                ProgressView(value: min(current.fraction, 1)).tint(.green)
                // 旧 → 新：之前几周（完整周）+ 本周（未结束）。目标设定前的整周不计入达成统计。
                let weeks = Array(previous.reversed()) + [current]
                let counted = weeks.filter(\.countsTowardCompletion)
                HStack(spacing: 6) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        Image(systemName: Self.symbol(for: week.outcome))
                            .foregroundStyle(week.outcome == .achieved ? Color.green : Color.secondary)
                    }
                    Text(Self.completionText(counted: counted, hasWeeksBeforeGoal: counted.count < weeks.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("progress.completion.summary")
            case .paused?:
                Text("已暂停，不计算进度").font(.footnote).foregroundStyle(.secondary)
            case nil:
                Text("进度暂时无法显示，可以下拉刷新重试。").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// 可比运动分析：最近一次运动与之前可比的同类运动比较；样本不足或不可比时明确说明原因。
private struct ComparableCard: View {
    let workout: WorkoutRecord?
    let service: any WorkoutHistoryService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("和过去的自己比")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
            if let workout {
                HStack(spacing: 8) {
                    Image(systemName: workout.activity.systemImage).foregroundStyle(.green)
                    Text("最近一次：\(workout.activity.title)")
                        .font(.headline)
                    Spacer()
                    Text(workout.startDate.formatted(.dateTime.month().day()))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                // 最近一次运动变化时重新读取；与运动页、运动详情的反馈同一来源。
                LatestComparison(workout: workout, service: service)
                    .id(workout.id)
            } else {
                Text("还没有运动可以比较。").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("progress.comparable")
    }
}

/// 最近一次运动与过去可比同类运动的简短对比，使用 `WorkoutFeedbackViewModel`（与运动页、运动详情相同的
/// 读取上限与心率读取名额），避免同一次运动在不同页面得出不同结论。
private struct LatestComparison: View {
    @State private var viewModel: WorkoutFeedbackViewModel

    init(workout: WorkoutRecord, service: any WorkoutHistoryService) {
        _viewModel = State(initialValue: WorkoutFeedbackViewModel(workout: workout, service: service))
    }

    var body: some View {
        content
            .task {
                if viewModel.state == .idle { await viewModel.load() }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loaded(let result):
            let feedback = result.feedback
            VStack(alignment: .leading, spacing: 10) {
                Text(WorkoutFeedbackPresentation.briefHeadline(feedback))
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("progress.comparable.headline")
                ForEach(WorkoutFeedbackPresentation.comparedLines(feedback), id: \.self) { line in
                    Text(line).font(.subheadline.weight(.medium))
                        .accessibilityIdentifier("progress.comparable.line")
                }
                if let line = WorkoutFeedbackPresentation.exclusionLine(feedback) {
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
                Text(WorkoutFeedbackPresentation.disclaimer)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .idle, .loading:
            HStack {
                ProgressView()
                Text("正在和过去的运动比较…").font(.footnote).foregroundStyle(.secondary)
            }
        case .noData:
            Text("这次运动不在已读取的范围内，暂时无法和过去比较。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .failed:
            VStack(alignment: .leading, spacing: 6) {
                Text("暂时没能和过去的运动比较。").font(.footnote).foregroundStyle(.secondary)
                Button("重试") { Task { await viewModel.load() } }
                    .buttonStyle(.bordered)
            }
        case .healthDataUnavailable, .needsAuthorization:
            EmptyView()
        }
    }
}

// MARK: - 身体状态

private struct InsightsContent: View {
    let viewModel: HealthInsightsViewModel
    let snapshot: HealthInsightsSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("身体状态（和自己的平时比较）")
                    .font(.headline)
                Text(BaselineComparison.baselineExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("insights.baselineExplanation")
            }
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
                if let explanation = kind.explanation {
                    Text(explanation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                switch state {
                case .value(let comparison):
                    values(comparison)
                case .noData:
                    Text("暂无数据").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    Text("没有读到记录。可能还没有数据，也可能还没有允许读取。").font(.caption).foregroundStyle(.secondary)
                case .failed(let error):
                    Label("暂时读不到", systemImage: "exclamationmark.triangle")
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
            column("平时（基线）", comparison.referenceMedian)
            Spacer(minLength: 0)
            if let direction = comparison.direction {
                Image(systemName: icon(direction))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        Text(comparison.shortText)
            .font(.footnote.weight(.semibold))
        // 默认只给通俗结论；中位数、样本天数在“数据依据与来源”中展开查看。
        Text(comparison.plainText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if comparison.excludedDays > 0 {
            Text("有 \(comparison.excludedDays) 天的数值明显异常（可能是记录错误），没有计入。")
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
                    Text("近两周没有读到睡眠记录。可能还没有数据，也可能还没有允许读取。").font(.caption).foregroundStyle(.secondary)
                case .failed(let error):
                    Label("暂时读不到", systemImage: "exclamationmark.triangle")
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
            Text("没有数据的日子留空，不当作 0。")
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
                Text("基线：\(range(snapshot.windows.reference))，取每天数值的中位数（排在中间的值，不受个别极端天影响）")
                Text("需要基线期至少 \(BaselineComparison.minimumReferenceDays) 天、近期至少 \(BaselineComparison.minimumObservationDays) 天有数据，否则显示“积累中”。")
                ForEach(detailLines, id: \.self) { line in
                    Text(line)
                }
                Text("数据来自 Apple“健康”中的静息心率、心率变异性（Apple 记录的是 SDNN 指标）与睡眠记录，只在本机计算，不上传。")
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

    /// 各指标的统计明细（中位数、样本天数），只在展开后显示。
    private var detailLines: [String] {
        [snapshot.restingHeartRate, snapshot.heartRateVariability].compactMap { state -> String? in
            guard let comparison = state.value else { return nil }
            return "\(comparison.kind.title)：\(comparison.detailText)"
        }
    }

    private func range(_ interval: DateInterval) -> String {
        let last = interval.end.addingTimeInterval(-1)
        return "\(interval.start.formatted(.dateTime.month().day()))–\(last.formatted(.dateTime.month().day()))"
    }
}

// MARK: - Previews（仅使用模拟数据，非真实数据）

@MainActor
private func previewInsights(
    health: MockHealthDataService,
    workouts: MockWorkoutHistoryService,
    goalInput: Double? = 3
) -> InsightsView {
    let goals = WorkoutGoalsViewModel(store: InMemoryWorkoutGoalStore(), service: workouts)
    if let goalInput {
        goals.add(metric: .workoutCount, activity: nil, input: goalInput)
    }
    return InsightsView(
        viewModel: HealthInsightsViewModel(service: health),
        service: health,
        progressViewModel: WorkoutAnalysisViewModel(
            loader: WorkoutAnalysisLoader(service: workouts, maximumHeartRateFetches: 0),
            limit: 200
        ),
        workoutService: workouts,
        goalsViewModel: goals
    )
}

#Preview("演示数据") {
    previewInsights(health: MockHealthDataService.demo(), workouts: MockWorkoutHistoryService.demo())
}

#Preview("还没设目标") {
    previewInsights(health: MockHealthDataService.demo(), workouts: MockWorkoutHistoryService.demo(), goalInput: nil)
}

#Preview("数据不足") {
    let health = MockHealthDataService(trends: [
        .restingHeartRate: .value((1...6).map { MetricDataPoint(date: Calendar.current.date(byAdding: .day, value: -$0, to: .now)!, value: 60) }),
    ])
    let workouts = MockWorkoutHistoryService(workouts: .value(Array(SimulatedWorkoutHistory.workouts(endingBefore: .now, count: 2))))
    return previewInsights(health: health, workouts: workouts)
}

#Preview("无数据") {
    previewInsights(health: MockHealthDataService(), workouts: MockWorkoutHistoryService(), goalInput: nil)
}

#Preview("需要授权") {
    let health = MockHealthDataService.demo()
    health.authorizationStatus = .shouldRequest
    return previewInsights(health: health, workouts: MockWorkoutHistoryService.demo())
}

#Preview("读取失败") {
    let health = MockHealthDataService(
        trends: [.restingHeartRate: .failure(.protectedDataUnavailable), .heartRateVariability: .failure(.protectedDataUnavailable)],
        sleepNights: .failure(.protectedDataUnavailable)
    )
    return previewInsights(health: health, workouts: MockWorkoutHistoryService(workouts: .failure(.protectedDataUnavailable)))
}
