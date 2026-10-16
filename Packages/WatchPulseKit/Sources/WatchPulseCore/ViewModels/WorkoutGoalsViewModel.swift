import Foundation
import Observation
import WatchPulseShared

/// 一个目标及其进度。
public struct WorkoutGoalItem: Identifiable, Hashable, Sendable {
    public let goal: WorkoutGoal
    /// 运动记录尚未读取成功时为 `nil`（目标本身仍可查看、编辑、删除）。
    public let progress: WorkoutGoalProgress?

    public var id: UUID { goal.id }
}

/// 个人运动目标（v0.3 T2）：本地目标 + 由 HealthKit 运动记录（任意来源）计算的每周进度。
///
/// 不预设目标数值，不自动调高；进度只描述完成情况，不做评价或建议。
@MainActor
@Observable
public final class WorkoutGoalsViewModel {
    public private(set) var goals: [WorkoutGoal] = []
    /// 运动记录的加载状态；与目标列表独立：读取失败时目标仍可管理。
    public private(set) var records: LoadState<WorkoutAnalysisSet> = .idle
    public private(set) var lastError: WorkoutGoalValidationError?

    @ObservationIgnored private let store: any WorkoutGoalStore
    @ObservationIgnored private let loader: WorkoutAnalysisLoader
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let fetchLimit: Int
    @ObservationIgnored private var isBusy = false
    /// 读取条数达到上限时，最早一条记录的开始时间（更早的周可能不完整）。
    @ObservationIgnored private var coverageStart: Date?

    public init(
        store: any WorkoutGoalStore,
        service: any WorkoutHistoryService,
        calendar: Calendar = .current,
        fetchLimit: Int = 200,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.store = store
        // 目标只需要次数 / 时长 / 距离，不读取心率曲线。
        loader = WorkoutAnalysisLoader(service: service, maximumHeartRateFetches: 0)
        self.calendar = calendar
        self.fetchLimit = fetchLimit
        self.now = now
        goals = store.allGoals()
    }

    public var dataOrigin: HealthDataOrigin { loader.dataOrigin }
    public var recoveredFromUnreadableData: Bool { store.recoveredFromUnreadableData }

    public var items: [WorkoutGoalItem] {
        let set = records.value
        let date = now()
        return goals.map { goal in
            WorkoutGoalItem(
                goal: goal,
                progress: set.map {
                    WorkoutGoalProgressCalculator.progress(
                        for: goal, records: $0.records, now: date, calendar: calendar, dataCoverageStart: coverageStart
                    )
                }
            )
        }
    }

    public func load() async {
        goals = store.allGoals()
        guard !isBusy else { return }
        guard loader.isHealthDataAvailable else {
            records = .healthDataUnavailable
            return
        }
        isBusy = true
        defer { isBusy = false }
        if records.value == nil { records = .loading }
        let limit = fetchLimit
        switch await capture({ [loader] in try await loader.load(limit: limit) }) {
        case .success(let set):
            coverageStart = set.records.count >= limit ? set.records.map(\.workout.startDate).min() : nil
            // 没有运动记录也要计算进度（本周 0），因此空集合同样视为已加载。
            records = .loaded(set)
        case .failure(let error):
            records = .from(error)
        }
    }

    /// 新建目标。目标值由用户输入（单位：次 / 分钟 / 公里）。
    @discardableResult
    public func add(metric: WorkoutGoalMetric, activity: WorkoutActivityKind?, input: Double) -> Bool {
        perform {
            try WorkoutGoal(
                id: UUID(), metric: metric, activity: activity,
                target: metric.storedValue(fromInput: input), createdAt: now()
            )
        }
    }

    @discardableResult
    public func update(_ goal: WorkoutGoal, metric: WorkoutGoalMetric, activity: WorkoutActivityKind?, input: Double) -> Bool {
        perform {
            try goal.updating(metric: metric, activity: activity, target: metric.storedValue(fromInput: input), now: now())
        }
    }

    public func setPaused(_ paused: Bool, for goal: WorkoutGoal) {
        store.save(goal.settingPaused(paused, now: now()))
        goals = store.allGoals()
    }

    public func delete(_ goal: WorkoutGoal) {
        store.delete(id: goal.id)
        goals = store.allGoals()
    }

    private func perform(_ make: () throws -> WorkoutGoal) -> Bool {
        do {
            store.save(try make())
            goals = store.allGoals()
            lastError = nil
            return true
        } catch let error as WorkoutGoalValidationError {
            lastError = error
            return false
        } catch {
            lastError = .targetNotPositive
            return false
        }
    }
}
