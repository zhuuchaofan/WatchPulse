import Foundation
import WatchPulseShared

/// 「进步」页使用的一周运动量。
public struct WeeklyVolume: Hashable, Sendable, Identifiable {
    public let interval: DateInterval
    public let isCurrentWeek: Bool
    public let workoutCount: Int
    public let totalDuration: TimeInterval
    public let totalDistanceMeters: Double

    public var id: Date { interval.start }

    /// 图表横轴标签：本周显示“本周”，其余显示周一的月/日。
    public var label: String {
        isCurrentWeek ? "本周" : interval.start.formatted(.dateTime.month().day())
    }
}

/// 「进步」页的数据：最近 4 周趋势 + 最近一次运动与过去同类运动的比较。
///
/// 由已有的 `WorkoutAnalysisSet` 计算：次数 / 时长 / 距离沿用 `WorkoutVolumeSummary`（疑似重复只计一次，
/// 缺失距离不补 0），比较沿用 `WorkoutFeedbackCalculator`（只描述数值高低，不评价进步或退步）。
public struct ProgressSummary: Hashable, Sendable {
    public static let weekCount = 4

    /// 从最早的一周到本周，共 `weekCount` 项。
    public let weeks: [WeeklyVolume]
    /// 最近一次运动（按开始时间）的比较结果；没有任何运动记录时为 `nil`。
    public let latestWorkout: WorkoutRecord?
    public let latestFeedback: WorkoutFeedback?
    /// 因疑似重复而未重复计入的条数。
    public let suspectedExcludedCount: Int
    /// 读取条数达到上限，较早的周可能偏低。
    public let mayBeIncomplete: Bool
    public let containsSimulatedData: Bool

    public var totalWorkouts: Int { weeks.map(\.workoutCount).reduce(0, +) }
    /// 有运动的周数。
    public var activeWeekCount: Int { weeks.filter { $0.workoutCount > 0 }.count }
    public var currentWeek: WeeklyVolume? { weeks.last }
    public var hasAnyWorkout: Bool { totalWorkouts > 0 }

    /// 趋势是否足够解读：至少两周有运动记录。不足时界面只陈述事实，不说“上升 / 下降”。
    public var hasEnoughWeeksForTrend: Bool { activeWeekCount >= 2 }

    public var headline: String {
        guard hasAnyWorkout else { return "最近 4 周还没有运动记录" }
        return "最近 4 周运动 \(totalWorkouts) 次"
    }

    public var detail: String {
        guard hasAnyWorkout else { return "完成一次运动后，这里会显示每周的变化。" }
        let weeks = "\(Self.weekCount) 周里有 \(activeWeekCount) 周有运动。"
        return hasEnoughWeeksForTrend ? weeks : weeks + "再多记录几周，就能看出变化。"
    }

    /// 给 VoiceOver 的图表描述。
    public var chartDescription: String {
        "最近 4 周每周运动次数：" + weeks.map { "\($0.label) \($0.workoutCount) 次" }.joined(separator: "，")
    }

    public static func make(
        from set: WorkoutAnalysisSet,
        readLimit: Int,
        now: Date,
        calendar: Calendar = .current
    ) -> ProgressSummary {
        let intervals = weekIntervals(endingAt: now, calendar: calendar)
        let weeks = intervals.enumerated().map { index, interval -> WeeklyVolume in
            let summary = WorkoutVolumeSummary.summarize(set.records, interval: interval, calendar: calendar)
            return WeeklyVolume(
                interval: interval,
                isCurrentWeek: index == intervals.count - 1,
                workoutCount: summary.workoutCount,
                totalDuration: summary.totalDuration,
                totalDistanceMeters: summary.totalDistanceMeters
            )
        }
        let covered = DateInterval(start: intervals.first?.start ?? now, end: intervals.last?.end ?? now)
        let inRange = WorkoutVolumeSummary.summarize(set.records, interval: covered, calendar: calendar)

        // 记录按开始时间倒序；第一条就是最近一次。
        let latest = set.records.first
        let oldest = set.records.map(\.workout.startDate).min()
        return ProgressSummary(
            weeks: weeks,
            latestWorkout: latest?.workout,
            latestFeedback: latest.map { WorkoutFeedbackCalculator.feedback(for: $0, among: set.records) },
            suspectedExcludedCount: inRange.suspectedExcludedCount,
            mayBeIncomplete: set.rawWorkoutCount >= readLimit && (oldest.map { $0 > covered.start } ?? false),
            containsSimulatedData: set.origin.isSimulated
        )
    }

    /// 本周及之前 3 周的区间（旧 → 新）。
    static func weekIntervals(endingAt now: Date, calendar: Calendar) -> [DateInterval] {
        guard let current = calendar.dateInterval(of: .weekOfYear, for: now) else {
            // 日历无法给出周区间时退回 7 天滚动窗口。
            return (0..<weekCount).reversed().map { offset in
                let end = now.addingTimeInterval(-Double(offset) * 7 * 86_400)
                return DateInterval(start: end.addingTimeInterval(-7 * 86_400), end: end)
            }
        }
        var result = [current]
        var weekStart = current.start
        for _ in 1..<weekCount {
            // 用“前一周中间的某个时刻”求周区间，避免夏令时当天 23 / 25 小时导致的边界偏差。
            guard let probe = calendar.date(byAdding: .day, value: -3, to: weekStart),
                  let week = calendar.dateInterval(of: .weekOfYear, for: probe) else { break }
            result.insert(week, at: 0)
            weekStart = week.start
        }
        return result
    }
}
