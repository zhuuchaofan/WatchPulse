import Foundation

/// 个人运动目标衡量的指标（每周）。
public enum WorkoutGoalMetric: String, CaseIterable, Hashable, Codable, Sendable {
    /// 每周运动次数。
    case workoutCount
    /// 每周运动总时长（秒）。
    case totalDuration
    /// 每周距离（米），只统计有距离记录的运动。
    case distance

    public var title: String {
        switch self {
        case .workoutCount: return "运动次数"
        case .totalDuration: return "运动总时长"
        case .distance: return "距离"
        }
    }

    /// 输入目标值时使用的单位（次 / 分钟 / 公里）。
    public var inputUnit: String {
        switch self {
        case .workoutCount: return "次"
        case .totalDuration: return "分钟"
        case .distance: return "公里"
        }
    }

    /// 输入值 → 存储值（次 / 秒 / 米）。
    public func storedValue(fromInput input: Double) -> Double {
        switch self {
        case .workoutCount: return input
        case .totalDuration: return input * 60
        case .distance: return input * 1000
        }
    }

    /// 存储值 → 输入值（次 / 分钟 / 公里）。
    public func inputValue(fromStored stored: Double) -> Double {
        switch self {
        case .workoutCount: return stored
        case .totalDuration: return stored / 60
        case .distance: return stored / 1000
        }
    }

    /// 按指标格式化存储值。
    public func format(_ stored: Double) -> String {
        switch self {
        case .workoutCount: return "\(Int(stored.rounded())) 次"
        case .totalDuration: return MetricFormatting.duration(seconds: stored)
        case .distance: return MetricFormatting.distance(meters: stored)
        }
    }
}

/// 目标校验失败的原因。
public enum WorkoutGoalValidationError: Error, Hashable, Sendable {
    /// 目标值必须是大于 0 的有限数。
    case targetNotPositive
    /// 次数目标必须是整数。
    case countNotWholeNumber
    /// 距离目标只能用于记录距离的运动类型（或全部运动）。
    case activityHasNoDistance
    /// 超出合理上限（防止误输入，例如多打了几个 0）。
    case targetTooLarge

    public var message: String {
        switch self {
        case .targetNotPositive: return "请输入大于 0 的目标值"
        case .countNotWholeNumber: return "次数需要是整数"
        case .activityHasNoDistance: return "该运动类型没有距离记录"
        case .targetTooLarge: return "目标值过大，请检查输入"
        }
    }
}

/// 用户设定的每周运动目标。仅保存在本机。
///
/// 目标值完全由用户输入：WatchPulse **不预设**“应该达到”的数值，也**不会自动调高**目标。
/// 进度只由「健康」中的运动记录（任意来源）计算，见 `WorkoutGoalProgressCalculator`。
public struct WorkoutGoal: Identifiable, Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let id: UUID
    public let metric: WorkoutGoalMetric
    /// 只统计某一类运动；`nil` 表示全部运动。
    public let activity: WorkoutActivityKind?
    /// 每周目标值（次 / 秒 / 米）。
    public let target: Double
    /// 暂停的目标保留设置，但不计算、不展示进度。
    public let isPaused: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let schemaVersion: Int

    public init(
        id: UUID,
        metric: WorkoutGoalMetric,
        activity: WorkoutActivityKind?,
        target: Double,
        isPaused: Bool = false,
        createdAt: Date,
        updatedAt: Date? = nil
    ) throws {
        try Self.validate(metric: metric, activity: activity, target: target)
        self.id = id
        self.metric = metric
        self.activity = activity
        self.target = target
        self.isPaused = isPaused
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        schemaVersion = Self.currentSchemaVersion
    }

    public static func validate(metric: WorkoutGoalMetric, activity: WorkoutActivityKind?, target: Double) throws {
        guard target.isFinite, target > 0 else { throw WorkoutGoalValidationError.targetNotPositive }
        switch metric {
        case .workoutCount:
            guard target == target.rounded() else { throw WorkoutGoalValidationError.countNotWholeNumber }
            guard target <= 100 else { throw WorkoutGoalValidationError.targetTooLarge }
        case .totalDuration:
            guard target <= 7 * 86_400 else { throw WorkoutGoalValidationError.targetTooLarge }
        case .distance:
            if let activity, !activity.tracksDistance { throw WorkoutGoalValidationError.activityHasNoDistance }
            guard target <= 10_000_000 else { throw WorkoutGoalValidationError.targetTooLarge }
        }
    }

    /// 修改指标、运动类型或目标值。保留 `id`、创建时间与暂停状态。
    public func updating(metric: WorkoutGoalMetric, activity: WorkoutActivityKind?, target: Double, now: Date) throws -> WorkoutGoal {
        try WorkoutGoal(id: id, metric: metric, activity: activity, target: target, isPaused: isPaused, createdAt: createdAt, updatedAt: now)
    }

    public func settingPaused(_ paused: Bool, now: Date) -> WorkoutGoal {
        // 原值已通过校验，这里不会失败。
        (try? WorkoutGoal(id: id, metric: metric, activity: activity, target: target, isPaused: paused, createdAt: createdAt, updatedAt: now)) ?? self
    }

    /// 例如“每周骑行距离 50 公里”“每周运动 3 次”。
    public var title: String {
        switch metric {
        case .workoutCount, .totalDuration: return "每周\(activity?.title ?? "运动") \(metric.format(target))"
        case .distance: return "每周\(activity?.title ?? "")距离 \(metric.format(target))"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, metric, activity, target, isPaused, createdAt, updatedAt, schemaVersion
    }

    /// 解码时同样校验：被篡改或不合法的存储数据不会变成目标。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            metric: container.decode(WorkoutGoalMetric.self, forKey: .metric),
            activity: container.decodeIfPresent(WorkoutActivityKind.self, forKey: .activity),
            target: container.decode(Double.self, forKey: .target),
            isPaused: container.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false,
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decodeIfPresent(Date.self, forKey: .updatedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(metric, forKey: .metric)
        try container.encodeIfPresent(activity, forKey: .activity)
        try container.encode(target, forKey: .target)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(schemaVersion, forKey: .schemaVersion)
    }
}

/// 某个目标在某一周的进度。只描述完成情况，不评价“好 / 坏”，不给出建议。
public struct WorkoutGoalWeekProgress: Hashable, Sendable {
    /// 自然周 `[start, end)`，由调用方的 `Calendar`（时区、每周第一天）决定。
    public let week: DateInterval
    /// 当前值（次 / 秒 / 米）。
    public let value: Double
    public let target: Double
    /// 计入的运动次数。
    public let countedWorkouts: Int
    /// 因疑似重复而只计一次、未重复计入的条数。
    public let suspectedDuplicatesExcluded: Int
    /// 距离目标：符合类型但没有距离记录（如室内骑行）而未计入距离的运动数。
    public let workoutsWithoutDistance: Int
    /// 本周尚未结束。
    public let isCurrentWeek: Bool
    /// 读取的运动记录可能没有覆盖整周（读取条数达到上限），数值可能偏低。
    public let mayBeIncomplete: Bool
    public let containsSimulatedData: Bool

    /// 完成比例，可大于 1（不截断，超额如实显示）。
    public var fraction: Double { target > 0 ? value / target : 0 }
    public var isAchieved: Bool { value >= target }
}

/// 目标进度：暂停的目标没有进度。
public enum WorkoutGoalProgress: Hashable, Sendable {
    case paused
    /// `current` 为本周；`previous` 为之前的完整周，按时间倒序。
    case active(current: WorkoutGoalWeekProgress, previous: [WorkoutGoalWeekProgress])
}

/// 由运动分析记录计算目标进度（确定性、可单测）。
///
/// - 只使用具备统计资格的记录（`WorkoutEligibility`）：疑似重复只计一次，时间无效的记录不计；
/// - 距离只计有距离记录的运动，缺失不补 0；
/// - 周按调用方传入的 `Calendar` 划分，记录按**开始时刻**归属，时长取运动有效秒数，跨时区 / 夏令时不重复、不丢失；
/// - 演示数据与真实数据不混合：分析集合本身只有一种来源。
public enum WorkoutGoalProgressCalculator {
    public static func progress(
        for goal: WorkoutGoal,
        records: [WorkoutAnalysisRecord],
        now: Date,
        calendar: Calendar,
        previousWeeks: Int = 3,
        dataCoverageStart: Date? = nil
    ) -> WorkoutGoalProgress {
        guard !goal.isPaused else { return .paused }
        guard let current = calendar.dateInterval(of: .weekOfYear, for: now) else {
            // 日历无法给出周区间时退回 7 天滚动窗口。
            let week = DateInterval(start: now.addingTimeInterval(-7 * 86_400), end: now)
            return .active(current: weekProgress(goal, records, week, true, dataCoverageStart, calendar), previous: [])
        }
        var previous: [WorkoutGoalWeekProgress] = []
        var weekStart = current.start
        for _ in 0..<max(0, previousWeeks) {
            // 用“前一周中间的某个时刻”求周区间，避免夏令时当天 23 / 25 小时导致的边界偏差。
            guard let probe = calendar.date(byAdding: .day, value: -3, to: weekStart),
                  let week = calendar.dateInterval(of: .weekOfYear, for: probe) else { break }
            previous.append(weekProgress(goal, records, week, false, dataCoverageStart, calendar))
            weekStart = week.start
        }
        return .active(current: weekProgress(goal, records, current, true, dataCoverageStart, calendar), previous: previous)
    }

    private static func weekProgress(
        _ goal: WorkoutGoal,
        _ records: [WorkoutAnalysisRecord],
        _ week: DateInterval,
        _ isCurrent: Bool,
        _ dataCoverageStart: Date?,
        _ calendar: Calendar
    ) -> WorkoutGoalWeekProgress {
        let matching = records.filter { goal.activity == nil || $0.workout.activity == goal.activity }
        let summary = WorkoutVolumeSummary.summarize(matching, interval: week, calendar: calendar)

        let value: Double
        let counted: Int
        var withoutDistance = 0
        switch goal.metric {
        case .workoutCount:
            value = Double(summary.workoutCount)
            counted = summary.workoutCount
        case .totalDuration:
            value = summary.totalDuration
            counted = summary.workoutCount
        case .distance:
            value = summary.totalDistanceMeters
            counted = summary.distanceWorkoutCount
            // 只统计本应有距离的运动类型（HIIT 等本来就没有距离，不算“缺失”）。
            withoutDistance = matching.filter {
                $0.workout.startDate >= week.start && $0.workout.startDate < week.end
                    && $0.eligibility.canCountInStatistics
                    && $0.workout.activity.tracksDistance
                    && !$0.eligibility.statisticsMetrics.contains(.distance)
            }.count
        }
        return WorkoutGoalWeekProgress(
            week: week,
            value: value,
            target: goal.target,
            countedWorkouts: counted,
            suspectedDuplicatesExcluded: summary.suspectedExcludedCount,
            workoutsWithoutDistance: withoutDistance,
            isCurrentWeek: isCurrent,
            mayBeIncomplete: dataCoverageStart.map { $0 > week.start } ?? false,
            containsSimulatedData: summary.containsSimulatedData
        )
    }
}
