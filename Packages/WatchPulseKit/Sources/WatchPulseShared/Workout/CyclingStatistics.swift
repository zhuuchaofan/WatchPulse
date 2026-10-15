import Foundation

extension WorkoutRecord {
    /// 运动均速（米 / 秒）= 记录距离 ÷ 有效运动时长（不含暂停），与实时仪表盘口径一致。
    public var averageSpeedMetersPerSecond: Double? {
        WorkoutSpeedMath.averageSpeed(distanceMeters: distanceMeters, activeDuration: duration)
    }
}

/// 一段时间内的骑行统计（来自运动记录，室内 / 室外都计入）。
public struct CyclingStatistics: Hashable, Sendable {
    public let rideCount: Int
    /// 有距离记录的骑行的总距离（米）。
    public let totalDistanceMeters: Double
    /// 所有骑行的有效运动时长（秒）。
    public let totalDuration: TimeInterval
    /// 有距离记录的骑行的总距离 ÷ 它们的总时长；没有距离记录时为 `nil`。
    public let averageSpeedMetersPerSecond: Double?
    /// 单次最长距离（米）。
    public let longestRideMeters: Double?
    public let interval: DateInterval

    /// 统计 `interval` 内开始的骑行；没有骑行返回 `nil`。
    public init?(workouts: [WorkoutRecord], interval: DateInterval) {
        let rides = workouts.filter { $0.activity == .cycling && interval.contains($0.startDate) }
        guard !rides.isEmpty else { return nil }
        let withDistance = rides.filter { ($0.distanceMeters ?? -1) >= 0 }
        rideCount = rides.count
        totalDistanceMeters = withDistance.compactMap(\.distanceMeters).reduce(0, +)
        totalDuration = rides.map(\.duration).reduce(0, +)
        averageSpeedMetersPerSecond = WorkoutSpeedMath.averageSpeed(
            distanceMeters: withDistance.isEmpty ? nil : totalDistanceMeters,
            activeDuration: withDistance.map(\.duration).reduce(0, +)
        )
        longestRideMeters = withDistance.compactMap(\.distanceMeters).max()
        self.interval = interval
    }

    /// 截至 `date` 的最近 `days` 天（含当天）。
    public static func recent(_ workouts: [WorkoutRecord], days: Int = 30, endingAt date: Date, calendar: Calendar = .current) -> CyclingStatistics? {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        let start = calendar.date(byAdding: .day, value: -days, to: end)!
        return CyclingStatistics(workouts: workouts, interval: DateInterval(start: start, end: end))
    }
}
