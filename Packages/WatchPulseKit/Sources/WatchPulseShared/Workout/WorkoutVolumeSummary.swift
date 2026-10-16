import Foundation

/// 一段时间内的运动量合计（次数 / 时长 / 距离），只统计具备统计资格的记录。
///
/// - 疑似重复默认只计一次，并在 `suspectedExcludedCount` 中明确给出；
/// - 缺失距离不补 0；距离合计与均速只含有距离的运动；
/// - 按天聚合由调用方传入 `Calendar`（含时区）：记录归属其**开始时刻**所在的当地日历日，
///   时长始终取运动的有效秒数，不用墙上时间相减，因此夏令时当天不会重复或丢失。
public struct WorkoutVolumeSummary: Hashable, Sendable {
    public struct DayBucket: Hashable, Sendable {
        public let dayStart: Date
        public let workoutCount: Int
        public let totalDuration: TimeInterval
        public let totalDistanceMeters: Double
    }

    public let interval: DateInterval
    public let workoutCount: Int
    public let totalDuration: TimeInterval
    public let totalDistanceMeters: Double
    /// 有距离记录的运动数。
    public let distanceWorkoutCount: Int
    /// 有距离记录的运动的总距离 ÷ 它们的总时长。
    public let averageSpeedMetersPerSecond: Double?
    public let dailyBuckets: [DayBucket]
    /// 区间内因疑似重复而未计入的条数。
    public let suspectedExcludedCount: Int
    /// 区间内因资格不足（如时间无效）而未计入的条数。
    public let ineligibleCount: Int
    public let containsSimulatedData: Bool

    public var hasSuspectedDuplicates: Bool { suspectedExcludedCount > 0 }

    public static func summarize(
        _ records: [WorkoutAnalysisRecord],
        interval: DateInterval,
        calendar: Calendar
    ) -> WorkoutVolumeSummary {
        // 半开区间 [start, end)：`DateInterval.contains` 包含终点，相邻两周 / 两天会把恰好落在边界上的运动各算一次。
        let inRange = records.filter { $0.workout.startDate >= interval.start && $0.workout.startDate < interval.end }
        let counted = inRange.filter(\.eligibility.canCountInStatistics)
        let withDistance = counted.filter { $0.eligibility.statisticsMetrics.contains(.distance) }
        let totalDistance = withDistance.compactMap(\.workout.distanceMeters).reduce(0, +)
        let distanceDuration = withDistance.map(\.workout.duration).reduce(0, +)

        let grouped = Dictionary(grouping: counted) { calendar.startOfDay(for: $0.workout.startDate) }
        let buckets = grouped.map { day, items in
            DayBucket(
                dayStart: day,
                workoutCount: items.count,
                totalDuration: items.map(\.workout.duration).reduce(0, +),
                totalDistanceMeters: items.filter { $0.eligibility.statisticsMetrics.contains(.distance) }
                    .compactMap(\.workout.distanceMeters).reduce(0, +)
            )
        }.sorted { $0.dayStart < $1.dayStart }

        return WorkoutVolumeSummary(
            interval: interval,
            workoutCount: counted.count,
            totalDuration: counted.map(\.workout.duration).reduce(0, +),
            totalDistanceMeters: totalDistance,
            distanceWorkoutCount: withDistance.count,
            averageSpeedMetersPerSecond: WorkoutSpeedMath.averageSpeed(
                distanceMeters: withDistance.isEmpty ? nil : totalDistance, activeDuration: distanceDuration
            ),
            dailyBuckets: buckets,
            suspectedExcludedCount: inRange.filter { $0.eligibility.blockers.contains(.excludedAsSuspectedDuplicate) }.count,
            ineligibleCount: inRange.filter {
                !$0.eligibility.canCountInStatistics && !$0.eligibility.blockers.contains(.excludedAsSuspectedDuplicate)
            }.count,
            containsSimulatedData: counted.contains { $0.isSimulated }
        )
    }
}
