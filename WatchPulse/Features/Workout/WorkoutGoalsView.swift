import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// 目标页（v0.3 T2）：本地保存的每周运动目标，进度由「健康」中的运动记录（任意来源）计算。
///
/// 目标数值由用户决定：不预设、不推荐、不自动调高；进度只描述完成情况，不做评价。
struct WorkoutGoalsView: View {
    let viewModel: WorkoutGoalsViewModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var editor: GoalEditorMode?

    var body: some View {
        NavigationStack {
            List {
                if viewModel.dataOrigin.isSimulated {
                    DemoModeBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if viewModel.recoveredFromUnreadableData {
                    Section {
                        Label("之前保存的目标无法读取，原始数据已备份，目标列表从空开始。", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                    }
                }

                if viewModel.goals.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("还没有目标", systemImage: "target")
                        } description: {
                            Text("设定每周的运动次数、总时长或距离。目标数值完全由你决定。")
                        } actions: {
                            Button("添加目标") { editor = .new }
                                .buttonStyle(.borderedProminent)
                        }
                        .accessibilityIdentifier("goals.empty")
                    }
                } else {
                    recordsStatus
                    Section {
                        ForEach(viewModel.items) { item in
                            // 不用 Button 包裹：保留行内各段文字为独立的无障碍元素（进度、说明）。
                            GoalRow(item: item)
                                .onTapGesture { editor = .edit(item.goal) }
                                .accessibilityElement(children: .contain)
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction(named: "编辑") { editor = .edit(item.goal) }
                                .accessibilityIdentifier("goals.row")
                            .swipeActions {
                                Button("删除", role: .destructive) { viewModel.delete(item.goal) }
                                Button(item.goal.isPaused ? "恢复" : "暂停") {
                                    viewModel.setPaused(!item.goal.isPaused, for: item.goal)
                                }
                                .tint(.orange)
                            }
                        }
                    } header: {
                        Text("每周目标")
                    }
                }

                Section {
                } footer: {
                    Text("进度根据「健康」中的运动记录计算（包括 Apple Watch「体能训练」和其他 App 的记录）；疑似重复的记录只计一次，没有距离的运动不计入距离。每周从日历设置的第一天开始。目标仅保存在本机，删除 App 或换机且未恢复备份会丢失。")
                }
            }
            .navigationTitle("目标")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editor = .new
                    } label: {
                        Label("添加目标", systemImage: "plus")
                    }
                    .accessibilityIdentifier("goals.add")
                }
            }
            .sheet(item: $editor) { mode in
                GoalEditor(mode: mode, viewModel: viewModel)
            }
            // 本周进度随新运动变化：每次切到本页、回到前台都重新读取（已有数据保留显示，不闪回加载中）。
            .task { await viewModel.load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, viewModel.records != .idle {
                    Task { await viewModel.load() }
                }
            }
            .refreshable { await viewModel.load() }
        }
    }

    /// 运动记录读取不成功时的说明；目标本身仍可管理。
    @ViewBuilder
    private var recordsStatus: some View {
        switch viewModel.records {
        case .idle, .loading:
            Section { ProgressView("正在读取运动记录…") }
        case .healthDataUnavailable:
            Section { Text("此设备不支持健康数据，无法计算进度。").font(.footnote) }
        case .needsAuthorization:
            Section { Text("请先在「健康」页完成授权，才能计算进度。").font(.footnote) }
        case .failed(let error):
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("运动记录读取失败，暂时无法计算进度：\(error.localizedDescription)").font(.footnote)
                    Button("重试") { Task { await viewModel.load() } }
                        .buttonStyle(.bordered)
                }
                .accessibilityIdentifier("goals.recordsFailed")
            }
        case .noData, .loaded:
            EmptyView()
        }
    }
}

private struct GoalRow: View {
    let item: WorkoutGoalItem

    private var metric: WorkoutGoalMetric { item.goal.metric }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: item.goal.activity?.systemImage ?? "figure.mixed.cardio")
                    .foregroundStyle(.green)
                Text(item.goal.title)
                    .font(.headline)
                Spacer()
                if item.goal.isPaused {
                    Text("已暂停")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            switch item.progress {
            case nil:
                Text("本周进度：--")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .paused?:
                Text("已暂停，不计算进度")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .active(let current, let previous)?:
                Text("本周 \(metric.format(current.value)) / \(metric.format(current.target))")
                    .font(.subheadline)
                    .monospacedDigit()
                    .accessibilityIdentifier("goals.progress")
                ProgressView(value: min(current.fraction, 1))
                    .tint(.green)
                Text(weekLabel(current.week) + (current.isAchieved ? " · 已达到目标" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(notes(for: current), id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !previous.isEmpty {
                    Text("之前几周：" + previous.map { "\(weekLabel($0.week)) \(metric.format($0.value))" }.joined(separator: "，"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func weekLabel(_ week: DateInterval) -> String {
        let last = week.end.addingTimeInterval(-1)
        return "\(week.start.formatted(.dateTime.month().day()))–\(last.formatted(.dateTime.month().day()))"
    }

    private func notes(for week: WorkoutGoalWeekProgress) -> [String] {
        var notes: [String] = []
        if week.suspectedDuplicatesExcluded > 0 {
            notes.append("含 \(week.suspectedDuplicatesExcluded) 条疑似重复记录，已只计一次")
        }
        if week.workoutsWithoutDistance > 0 {
            notes.append("\(week.workoutsWithoutDistance) 次运动没有距离记录，未计入距离")
        }
        if week.mayBeIncomplete {
            notes.append("读取的运动记录可能未覆盖整周，数值可能偏低")
        }
        return notes
    }
}

enum GoalEditorMode: Identifiable {
    case new
    case edit(WorkoutGoal)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let goal): return goal.id.uuidString
        }
    }
}

/// 新建 / 编辑目标。目标值输入框初始为空（新建时），不提供推荐值。
private struct GoalEditor: View {
    let mode: GoalEditorMode
    let viewModel: WorkoutGoalsViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var metric: WorkoutGoalMetric
    @State private var activity: WorkoutActivityKind?
    @State private var targetText: String
    @State private var error: WorkoutGoalValidationError?

    init(mode: GoalEditorMode, viewModel: WorkoutGoalsViewModel) {
        self.mode = mode
        self.viewModel = viewModel
        switch mode {
        case .new:
            _metric = State(initialValue: .workoutCount)
            _activity = State(initialValue: nil)
            _targetText = State(initialValue: "")
        case .edit(let goal):
            _metric = State(initialValue: goal.metric)
            _activity = State(initialValue: goal.activity)
            let input = goal.metric.inputValue(fromStored: goal.target)
            _targetText = State(initialValue: input == input.rounded() ? String(Int(input)) : String(input))
        }
    }

    private var editingGoal: WorkoutGoal? {
        if case .edit(let goal) = mode { return goal }
        return nil
    }

    private var activityChoices: [WorkoutActivityKind] {
        WorkoutActivityKind.allCases.filter { metric != .distance || $0.tracksDistance }
    }

    private var parsedInput: Double? {
        Double(targetText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("指标", selection: $metric) {
                        ForEach(WorkoutGoalMetric.allCases, id: \.self) { metric in
                            Text(metric.title).tag(metric)
                        }
                    }
                    .accessibilityIdentifier("goalEditor.metric")
                    Picker("运动类型", selection: $activity) {
                        Text("全部运动").tag(WorkoutActivityKind?.none)
                        ForEach(activityChoices, id: \.self) { kind in
                            Text(kind.title).tag(Optional(kind))
                        }
                    }
                }

                Section {
                    HStack {
                        TextField("每周目标", text: $targetText)
                            .keyboardType(metric == .workoutCount ? .numberPad : .decimalPad)
                            .accessibilityIdentifier("goalEditor.target")
                        Text(metric.inputUnit)
                            .foregroundStyle(.secondary)
                    }
                    if let error {
                        Text(error.message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("数值由你决定，WatchPulse 不推荐数值，也不会自动调高。")
                }

                if let goal = editingGoal {
                    Section {
                        Button(goal.isPaused ? "恢复目标" : "暂停目标") {
                            viewModel.setPaused(!goal.isPaused, for: goal)
                            dismiss()
                        }
                        .accessibilityIdentifier("goalEditor.togglePause")
                        Button("删除目标", role: .destructive) {
                            viewModel.delete(goal)
                            dismiss()
                        }
                        .accessibilityIdentifier("goalEditor.delete")
                    } footer: {
                        Text("暂停的目标保留设置，但不计算进度。删除后无法恢复，不影响「健康」中的运动记录。")
                    }
                }
            }
            .navigationTitle(editingGoal == nil ? "添加目标" : "编辑目标")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: metric) { _, newMetric in
                if newMetric == .distance, let activity, !activity.tracksDistance {
                    self.activity = nil
                }
                error = nil
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(parsedInput == nil)
                        .accessibilityIdentifier("goalEditor.save")
                }
            }
        }
    }

    private func save() {
        guard let input = parsedInput else { return }
        let saved: Bool
        if let goal = editingGoal {
            saved = viewModel.update(goal, metric: metric, activity: activity, input: input)
        } else {
            saved = viewModel.add(metric: metric, activity: activity, input: input)
        }
        if saved {
            dismiss()
        } else {
            error = viewModel.lastError
        }
    }
}

#Preview("演示模式") {
    WorkoutGoalsView(
        viewModel: WorkoutGoalsViewModel(store: InMemoryWorkoutGoalStore(), service: MockWorkoutHistoryService.demo())
    )
}
