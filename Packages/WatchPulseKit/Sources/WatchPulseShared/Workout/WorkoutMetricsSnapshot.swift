import Foundation

/// 某一时刻的运动指标快照。
///
/// 后续由 Watch 端从 `HKLiveWorkoutBuilder` 的统计数据汇总得到，
/// 通过 `HKWorkoutSession.sendToRemoteWorkoutSession(data:)` 发给 iPhone。
public struct WorkoutMetricsSnapshot: Hashable, Codable, Sendable {
    public let timestamp: Date
    /// 运动已进行时长（秒）。
    public let elapsedTime: TimeInterval
    public let heartRateBPM: Double?
    public let activeEnergyKilocalories: Double?
    public let distanceMeters: Double?

    public init(
        timestamp: Date,
        elapsedTime: TimeInterval,
        heartRateBPM: Double? = nil,
        activeEnergyKilocalories: Double? = nil,
        distanceMeters: Double? = nil
    ) {
        self.timestamp = timestamp
        self.elapsedTime = elapsedTime
        self.heartRateBPM = heartRateBPM
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.distanceMeters = distanceMeters
    }
}

extension WorkoutMetricsSnapshot {
    /// 推算 `date` 时刻的运动时长：运动进行中时在快照基础上加上经过的时间。
    public func elapsedTime(at date: Date, isRunning: Bool) -> TimeInterval {
        guard isRunning else { return elapsedTime }
        return elapsedTime + max(0, date.timeIntervalSince(timestamp))
    }

    /// 以 `date` 为新的时间基准（用于暂停后继续：暂停期间不计时）。
    public func rebased(to date: Date) -> WorkoutMetricsSnapshot {
        WorkoutMetricsSnapshot(
            timestamp: max(date, timestamp),
            elapsedTime: elapsedTime,
            heartRateBPM: heartRateBPM,
            activeEnergyKilocalories: activeEnergyKilocalories,
            distanceMeters: distanceMeters
        )
    }
}
