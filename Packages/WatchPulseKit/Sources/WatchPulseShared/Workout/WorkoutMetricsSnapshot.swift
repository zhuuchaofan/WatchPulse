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
    /// GPS 等来源的速度（v0.2 新增，可选）。旧版本消息没有此字段，解码为 `nil`；
    /// 旧版本 App 收到新消息时会忽略此字段。
    public let speed: WorkoutSpeedSample?

    public init(
        timestamp: Date,
        elapsedTime: TimeInterval,
        heartRateBPM: Double? = nil,
        activeEnergyKilocalories: Double? = nil,
        distanceMeters: Double? = nil,
        speed: WorkoutSpeedSample? = nil
    ) {
        self.timestamp = timestamp
        self.elapsedTime = elapsedTime
        self.heartRateBPM = heartRateBPM
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.distanceMeters = distanceMeters
        self.speed = speed
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, elapsedTime, heartRateBPM, activeEnergyKilocalories, distanceMeters, speed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        elapsedTime = try container.decode(TimeInterval.self, forKey: .elapsedTime)
        heartRateBPM = try container.decodeIfPresent(Double.self, forKey: .heartRateBPM)
        activeEnergyKilocalories = try container.decodeIfPresent(Double.self, forKey: .activeEnergyKilocalories)
        distanceMeters = try container.decodeIfPresent(Double.self, forKey: .distanceMeters)
        // v0.2 新增：缺失（旧版本 Watch）或无法解析时为 `nil`，不影响其他指标。
        let decodedSpeed = try? container.decodeIfPresent(WorkoutSpeedSample.self, forKey: .speed)
        speed = decodedSpeed.map {
            // 经过 init 重新约束：质量不允许展示时丢弃数值。
            WorkoutSpeedSample(metersPerSecond: $0.metersPerSecond, sampleDate: $0.sampleDate, source: $0.source, quality: $0.quality)
        }
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
            distanceMeters: distanceMeters,
            speed: speed
        )
    }

    /// 替换速度，其余字段（含时间戳与时长）保持不变。
    public func with(speed: WorkoutSpeedSample?) -> WorkoutMetricsSnapshot {
        WorkoutMetricsSnapshot(
            timestamp: timestamp,
            elapsedTime: elapsedTime,
            heartRateBPM: heartRateBPM,
            activeEnergyKilocalories: activeEnergyKilocalories,
            distanceMeters: distanceMeters,
            speed: speed
        )
    }

    /// 运动均速（米 / 秒）= 运动记录距离 ÷ 有效运动时长（不含暂停）。
    /// 时长不足 1 秒或没有距离时为 `nil`（不显示 0）。
    public var averageSpeedMetersPerSecond: Double? {
        WorkoutSpeedMath.averageSpeed(distanceMeters: distanceMeters, activeDuration: elapsedTime)
    }
}

/// 速度相关的口径统一放在这里，实时仪表盘与运动记录使用同一定义。
public enum WorkoutSpeedMath {
    /// 运动均速：距离 ÷ 有效运动时长（不含暂停）。不足 1 秒或距离缺失返回 `nil`。
    public static func averageSpeed(distanceMeters: Double?, activeDuration: TimeInterval) -> Double? {
        guard let distanceMeters, distanceMeters.isFinite, distanceMeters >= 0,
              activeDuration.isFinite, activeDuration >= 1 else { return nil }
        return distanceMeters / activeDuration
    }
}
