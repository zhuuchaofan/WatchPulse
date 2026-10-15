import Foundation

/// 最近一晚的睡眠分期与近两周的作息规律（描述性统计，不做医学判断）。
public struct SleepInsight: Hashable, Sendable {
    /// 一个阶段的时长与占比。
    public struct StageShare: Hashable, Sendable, Identifiable {
        public let stage: SleepStage
        public let duration: TimeInterval
        /// 占睡着 + 清醒总时长的比例（0…1）。
        public let fraction: Double

        public var id: SleepStage { stage }
    }

    /// 入睡 / 醒来时间的规律性。
    public struct Regularity: Hashable, Sendable {
        public let nightCount: Int
        /// 平均睡着时长（只有卧床记录的夜晚用卧床时长）。
        public let averageDuration: TimeInterval
        /// 平均入睡时刻（距当天 0 点的分钟数，可能为负表示前一天晚上）。
        public let averageBedtimeMinutes: Double
        public let averageWakeMinutes: Double
        /// 入睡 / 醒来时刻的标准差（分钟）。
        public let bedtimeDeviationMinutes: Double
        public let wakeDeviationMinutes: Double
    }

    /// 最近一次有记录的夜晚。
    public let latestNight: SleepNight?
    /// 最近一晚各阶段（深睡、REM、核心、未细分、清醒），按固定顺序，只含有时长的阶段。
    public let stages: [StageShare]
    /// 最近一晚是否只有卧床记录（无法推断实际睡着时长）。
    public let isInBedOnly: Bool
    /// 最近一晚是否有分期（核心 / 深睡 / REM）。
    public let hasStages: Bool
    /// 近期规律性；有记录的夜晚少于 `minimumNightsForRegularity` 时为 `nil`。
    public let regularity: Regularity?
    /// 统计区间内有记录的夜晚数。
    public let nightCount: Int

    public static let minimumNightsForRegularity = 4
    public static let regularityDays = 14

    /// - Parameters:
    ///   - nights: `interval` 内的夜晚（任意顺序）。
    ///   - now: 用于排除未来日期的夜晚。
    public init(nights: [SleepNight], now: Date, calendar: Calendar = .current) {
        let valid = nights
            .filter { $0.date <= calendar.startOfDay(for: now) && $0.end > $0.start }
            .sorted { $0.date < $1.date }
        nightCount = valid.count
        latestNight = valid.last

        if let night = valid.last {
            isInBedOnly = night.isInBedOnly
            let order: [SleepStage] = [.deep, .rem, .core, .asleepUnspecified, .awake]
            let total = order.compactMap { night.stageDurations[$0] }.reduce(0, +)
            stages = total > 0
                ? order.compactMap { stage in
                    guard let duration = night.stageDurations[stage], duration > 0 else { return nil }
                    return StageShare(stage: stage, duration: duration, fraction: duration / total)
                }
                : []
            hasStages = [.deep, .rem, .core].contains { (night.stageDurations[$0] ?? 0) > 0 }
        } else {
            isInBedOnly = false
            stages = []
            hasStages = false
        }

        if valid.count >= Self.minimumNightsForRegularity {
            let bedtimes = valid.map { Self.minutesFromMidnight($0.start, nightDate: $0.date, calendar: calendar) }
            let wakes = valid.map { Self.minutesFromMidnight($0.end, nightDate: $0.date, calendar: calendar) }
            regularity = Regularity(
                nightCount: valid.count,
                averageDuration: valid.map(\.primaryDuration).reduce(0, +) / Double(valid.count),
                averageBedtimeMinutes: Self.mean(bedtimes),
                averageWakeMinutes: Self.mean(wakes),
                bedtimeDeviationMinutes: Self.standardDeviation(bedtimes),
                wakeDeviationMinutes: Self.standardDeviation(wakes)
            )
        } else {
            regularity = nil
        }
    }

    /// 相对“醒来那天 0 点”的分钟数：前一晚 23:30 → −30，当天 07:00 → 420。
    /// 用墙上时间计算，夏令时切换不会让入睡时刻偏移一小时。
    static func minutesFromMidnight(_ date: Date, nightDate: Date, calendar: Calendar) -> Double {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = Double((components.hour ?? 0) * 60 + (components.minute ?? 0))
        return calendar.isDate(date, inSameDayAs: nightDate) ? minutes : minutes - 1_440
    }

    static func mean(_ values: [Double]) -> Double {
        values.reduce(0, +) / Double(values.count)
    }

    static func standardDeviation(_ values: [Double]) -> Double {
        let average = mean(values)
        return (values.map { ($0 - average) * ($0 - average) }.reduce(0, +) / Double(values.count)).squareRoot()
    }
}

extension SleepStage {
    /// 分析页使用的阶段名称。
    public var insightTitle: String {
        switch self {
        case .deep: return "深睡"
        case .rem: return "REM"
        case .core: return "核心"
        case .asleepUnspecified: return "睡眠（未分期）"
        case .awake: return "清醒"
        case .inBed: return "卧床"
        }
    }
}

extension MetricFormatting {
    /// 距 0 点的分钟数 → “23:40” / “07:05”（负数表示前一天）。
    public static func clockTime(minutesFromMidnight minutes: Double) -> String {
        var total = Int(minutes.rounded()) % 1_440
        if total < 0 { total += 1_440 }
        let hours = total / 60
        let mins = total % 60
        return (hours < 10 ? "0" : "") + "\(hours):" + (mins < 10 ? "0" : "") + "\(mins)"
    }
}
