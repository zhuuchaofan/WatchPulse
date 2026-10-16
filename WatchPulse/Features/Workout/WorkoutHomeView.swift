import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// 训练中心：本周目标 → 开始运动 / 实时运动 → 最近一次运动反馈 → 最近记录（+ 演示模式控制）。
struct WorkoutHomeView: View {
    let monitor: LiveWorkoutMonitor
    let simulatedWorkout: SimulatedMirroredWorkout?
    let historyService: any WorkoutHistoryService
    let goalsViewModel: WorkoutGoalsViewModel
    var onOpenGoals: () -> Void = {}
    var onSimulatedWorkoutCompleted: @MainActor (WorkoutRecord, [HeartRatePoint]) -> Void = { _, _ in }

    @State private var historyViewModel: WorkoutHistoryViewModel

    init(
        monitor: LiveWorkoutMonitor,
        simulatedWorkout: SimulatedMirroredWorkout?,
        historyService: any WorkoutHistoryService,
        goalsViewModel: WorkoutGoalsViewModel,
        onOpenGoals: @escaping () -> Void = {},
        onSimulatedWorkoutCompleted: @escaping @MainActor (WorkoutRecord, [HeartRatePoint]) -> Void = { _, _ in }
    ) {
        self.monitor = monitor
        self.simulatedWorkout = simulatedWorkout
        self.historyService = historyService
        self.goalsViewModel = goalsViewModel
        self.onOpenGoals = onOpenGoals
        self.onSimulatedWorkoutCompleted = onSimulatedWorkoutCompleted
        _historyViewModel = State(initialValue: WorkoutHistoryViewModel(service: historyService))
    }

    var body: some View {
        NavigationStack {
            List {
                if monitor.dataOrigin.isSimulated {
                    DemoModeBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("本周目标") {
                    WeeklyGoalCard(viewModel: goalsViewModel, onOpenGoals: onOpenGoals)
                }

                Section("开始运动") {
                    if monitor.hasWorkout {
                        NavigationLink {
                            LiveWorkoutDashboardView(monitor: monitor)
                        } label: {
                            LiveWorkoutRow(monitor: monitor)
                        }
                        .accessibilityIdentifier("workout.liveRow")
                    } else {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("在 Apple Watch 上开始运动")
                                    .font(.headline)
                                Text("打开 Apple Watch 上的 WatchPulse，选好运动类型再开始，iPhone 会自动显示实时心率、能量和距离。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "applewatch.radiowaves.left.and.right")
                                .font(.title2)
                                .foregroundStyle(.green)
                        }
                        .accessibilityIdentifier("workout.waiting")
                    }
                }

                if let simulatedWorkout {
                    SimulationControls(simulation: simulatedWorkout)
                }

                if let latest = latestWorkout {
                    // 按运动 ID 区分：最近一次运动变了，就重新创建反馈 ViewModel。
                    ForEach([latest]) { workout in
                        LatestWorkoutSection(workout: workout, service: historyService)
                    }
                }

                WorkoutRecentSection(viewModel: historyViewModel)
            }
            .navigationTitle("运动")
            .navigationDestination(for: WorkoutRecord.self) { workout in
                WorkoutDetailScreen(workout: workout, service: historyService)
            }
            .task {
                if historyViewModel.state == .idle {
                    await historyViewModel.load()
                }
                await goalsViewModel.load()
            }
            .refreshable {
                await historyViewModel.load()
                await goalsViewModel.load()
            }
            .onChange(of: monitor.phase) { _, phase in
                // 运动结束后 Apple Watch 会把记录写入 HealthKit，稍后刷新列表。
                guard phase == .ended else { return }
                Task {
                    if let completed = simulatedWorkout?.watch.completedWorkout {
                        onSimulatedWorkoutCompleted(completed, monitor.heartRateHistory)
                    } else {
                        try? await Task.sleep(for: .seconds(3))
                    }
                    await historyViewModel.load()
                    await goalsViewModel.load()
                }
            }
        }
    }

    /// 已读取的运动记录中开始时间最近的一条。
    private var latestWorkout: WorkoutRecord? {
        historyViewModel.state.value?.max { $0.startDate < $1.startDate }
    }
}

private struct LiveWorkoutRow: View {
    let monitor: LiveWorkoutMonitor

    var body: some View {
        HStack {
            Image(systemName: monitor.configuration?.activity.systemImage ?? "figure.run")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.configuration?.activity.title ?? "运动")
                    .font(.headline)
                Text("\(monitor.phase.title) · \(monitor.connection.title)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(MetricFormatting.clock(seconds: monitor.elapsedTime(at: context.date)))
                    .font(.headline)
                    .monospacedDigit()
            }
        }
    }
}

/// 演示模式：在 iPhone 上模拟一只 Apple Watch 发起运动，用于验证实时仪表盘、命令与断线恢复流程。
private struct SimulationControls: View {
    let simulation: SimulatedMirroredWorkout

    var body: some View {
        Section {
            if simulation.watch.phase.isActive {
                if simulation.isOutageActive {
                    Button("恢复连接") { simulation.endOutage() }
                        .accessibilityIdentifier("demo.endOutage")
                } else {
                    Button("模拟断线") { simulation.beginOutage() }
                        .accessibilityIdentifier("demo.beginOutage")
                }
                LabeledContent("模拟 Watch 状态", value: simulation.watch.phase.title)
                LabeledContent(
                    "Watch 镜像连接",
                    value: simulation.watch.isMirroringConnected ? "已连接" : (simulation.watch.isReconnecting ? "重连中" : "未连接")
                )
            } else {
                ForEach([WorkoutActivityKind.running, .cycling, .highIntensityIntervalTraining], id: \.self) { activity in
                    Button {
                        Task {
                            await simulation.start(WorkoutConfigurationRequest(activity: activity, location: .outdoor))
                            simulation.startLoop()
                        }
                    } label: {
                        Label("开始模拟\(activity.title)", systemImage: activity.systemImage)
                    }
                    .accessibilityIdentifier("demo.start.\(activity.rawValue)")
                }
            }
        } header: {
            Text("演示：模拟 Apple Watch")
        } footer: {
            Text("仅演示模式可用。数据由模拟器生成，不来自真实设备，也不会写入“健康”。")
        }
    }
}

// MARK: - 本周目标

/// 训练中心顶部的本周目标：只展示第一个未暂停的目标和它的进度；管理目标在「目标」页。
/// 进度只描述完成情况，不评价、不推荐目标数值。
private struct WeeklyGoalCard: View {
    let viewModel: WorkoutGoalsViewModel
    let onOpenGoals: () -> Void

    var body: some View {
        if viewModel.goals.isEmpty {
            emptyGoals
        } else {
            let active = viewModel.items.filter { !$0.goal.isPaused }
            if let first = active.first {
                activeGoal(first, others: active.count - 1)
            } else {
                allPaused
            }
        }
    }

    private var emptyGoals: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("还没有每周目标", systemImage: "target")
                .font(.headline)
            Text("设一个每周想完成的运动次数、时长或距离，数值完全由你决定。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("设定目标", action: onOpenGoals)
                .buttonStyle(.borderedProminent)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workout.goalEmpty")
    }

    private var allPaused: some View {
        Button(action: onOpenGoals) {
            VStack(alignment: .leading, spacing: 4) {
                Label("目标已暂停", systemImage: "pause.circle")
                    .font(.headline)
                Text("暂停期间不计算进度。到「目标」页可以恢复。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout.goalCard")
    }

    private func activeGoal(_ item: WorkoutGoalItem, others: Int) -> some View {
        Button(action: onOpenGoals) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: item.goal.activity?.systemImage ?? "figure.mixed.cardio")
                        .foregroundStyle(.green)
                    Text(item.goal.title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                progress(item)
                if others > 0 {
                    Text("还有 \(others) 个目标，点开查看")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workout.goalCard")
    }

    @ViewBuilder
    private func progress(_ item: WorkoutGoalItem) -> some View {
        if case .active(let current, _)? = item.progress {
            let metric = item.goal.metric
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(metric.format(current.value))
                    .font(.title.weight(.bold))
                    .monospacedDigit()
                Text("/ \(metric.format(current.target))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("workout.goalProgress")
            ProgressView(value: min(current.fraction, 1))
                .tint(.green)
            Text(current.isAchieved ? "本周目标已达成" : "还差 \(metric.format(max(0, current.target - current.value)))就达成本周目标")
                .font(.footnote)
            if current.mayBeIncomplete {
                Text("读取的运动记录可能没有覆盖整周，数值可能偏低。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if case .loaded(let set) = viewModel.records, set.records.isEmpty {
                // 0 次可能是没运动，也可能没有读取权限，不能当作正常进度静默显示。
                Text("没有读到运动记录，所以进度是 0。如果最近有运动，请检查是否允许读取“体能训练”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            recordsHint
        }
    }

    /// 运动记录还没有读取成功时的说明；目标本身不受影响。
    @ViewBuilder
    private var recordsHint: some View {
        switch viewModel.records {
        case .idle, .loading:
            ProgressView("正在读取运动记录…")
        case .healthDataUnavailable:
            Text("这台设备用不了“健康”，无法计算进度。").font(.footnote).foregroundStyle(.secondary)
        case .needsAuthorization:
            Text("请先在「今日」页允许读取健康数据，才能计算进度。").font(.footnote).foregroundStyle(.secondary)
        case .failed:
            Text("暂时没能读取运动记录，本周进度无法更新。下拉刷新可以重试。").font(.footnote).foregroundStyle(.secondary)
        case .noData, .loaded:
            Text("本周进度暂时无法显示。").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 最近一次运动

/// 最近一次运动 + 与过去可比同类运动的简短对比。完整反馈与心率曲线在运动详情。
private struct LatestWorkoutSection: View {
    let workout: WorkoutRecord
    @State private var feedbackViewModel: WorkoutFeedbackViewModel

    init(workout: WorkoutRecord, service: any WorkoutHistoryService) {
        self.workout = workout
        _feedbackViewModel = State(initialValue: WorkoutFeedbackViewModel(workout: workout, service: service))
    }

    var body: some View {
        Section("最近一次运动") {
            NavigationLink(value: workout) {
                WorkoutRow(workout: workout)
            }
            .accessibilityIdentifier("workout.latest")
            feedback
        }
        .task {
            if feedbackViewModel.state == .idle {
                await feedbackViewModel.load()
            }
        }
    }

    @ViewBuilder
    private var feedback: some View {
        switch feedbackViewModel.state {
        case .loaded(let result):
            VStack(alignment: .leading, spacing: 6) {
                Text(WorkoutFeedbackPresentation.briefHeadline(result.feedback))
                    .font(.footnote)
                    .accessibilityIdentifier("workout.latest.feedback")
                ForEach(WorkoutFeedbackPresentation.comparedLines(result.feedback), id: \.self) { line in
                    Text(line).font(.footnote.weight(.medium))
                }
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
                Button("重试") { Task { await feedbackViewModel.load() } }
                    .buttonStyle(.bordered)
            }
        case .healthDataUnavailable, .needsAuthorization:
            EmptyView()
        }
    }
}

// MARK: - Previews（仅使用模拟数据，非真实数据）

#Preview("演示模式 · 有目标") {
    let service = MockWorkoutHistoryService.demo()
    let goals = WorkoutGoalsViewModel(store: InMemoryWorkoutGoalStore(), service: service)
    goals.add(metric: .workoutCount, activity: nil, input: 3)
    let monitor = LiveWorkoutMonitor(dataOrigin: .simulated)
    return WorkoutHomeView(
        monitor: monitor,
        simulatedWorkout: SimulatedMirroredWorkout(monitor: monitor),
        historyService: service,
        goalsViewModel: goals
    )
}

#Preview("演示模式 · 还没设目标") {
    let service = MockWorkoutHistoryService.demo()
    let monitor = LiveWorkoutMonitor(dataOrigin: .simulated)
    return WorkoutHomeView(
        monitor: monitor,
        simulatedWorkout: SimulatedMirroredWorkout(monitor: monitor),
        historyService: service,
        goalsViewModel: WorkoutGoalsViewModel(store: InMemoryWorkoutGoalStore(), service: service)
    )
}

#Preview("无记录") {
    let service = MockWorkoutHistoryService()
    return WorkoutHomeView(
        monitor: LiveWorkoutMonitor(dataOrigin: .healthKit),
        simulatedWorkout: nil,
        historyService: service,
        goalsViewModel: WorkoutGoalsViewModel(store: InMemoryWorkoutGoalStore(), service: service)
    )
}

#Preview("读取失败") {
    let service = MockWorkoutHistoryService(workouts: .failure(.protectedDataUnavailable))
    return WorkoutHomeView(
        monitor: LiveWorkoutMonitor(dataOrigin: .healthKit),
        simulatedWorkout: nil,
        historyService: service,
        goalsViewModel: WorkoutGoalsViewModel(store: InMemoryWorkoutGoalStore(), service: service)
    )
}
