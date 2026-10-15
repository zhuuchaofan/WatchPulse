import Foundation

/// 数据来源：真实 HealthKit 数据还是模拟数据。界面必须据此明确标注模拟数据。
public enum HealthDataOrigin: String, Hashable, Codable, Sendable {
    case healthKit
    case simulated

    public var isSimulated: Bool { self == .simulated }
}

/// 某项指标的摘要值（最新值 / 今日累计 / 昨晚睡眠）。
public struct MetricSummaryValue: Hashable, Codable, Sendable {
    public let kind: HealthMetricKind
    /// 数值，单位见 `HealthMetricKind.unitLabel`（睡眠为小时）。
    public let value: Double
    /// 数值对应的时间：离散值为采样结束时间，累计值为当天零点，睡眠为醒来时间。
    public let date: Date
    public let sourceName: String?
    /// 仅睡眠：该夜的详细分期。
    public let sleepNight: SleepNight?

    public init(kind: HealthMetricKind, value: Double, date: Date, sourceName: String? = nil, sleepNight: SleepNight? = nil) {
        self.kind = kind
        self.value = value
        self.date = date
        self.sourceName = sourceName
        self.sleepNight = sleepNight
    }
}

/// 趋势图中的一个数据点（按天聚合）。
public struct MetricDataPoint: Identifiable, Hashable, Codable, Sendable {
    /// 当天零点（睡眠为醒来那天零点）。
    public let date: Date
    public let value: Double
    public let minimum: Double?
    public let maximum: Double?

    public var id: Date { date }

    public init(date: Date, value: Double, minimum: Double? = nil, maximum: Double? = nil) {
        self.date = date
        self.value = value
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// 趋势时间范围。
public enum TrendPeriod: String, CaseIterable, Codable, Sendable, Identifiable {
    case week
    case month
    case quarter

    public var id: String { rawValue }

    public var dayCount: Int {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        }
    }

    public var title: String {
        switch self {
        case .week: return "7 天"
        case .month: return "30 天"
        case .quarter: return "90 天"
        }
    }

    /// 截至 `date` 当天（含当天）的整天区间。
    public func interval(endingAt date: Date, calendar: Calendar = .current) -> DateInterval {
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
        let start = calendar.date(byAdding: .day, value: -dayCount, to: endOfToday)!
        return DateInterval(start: start, end: endOfToday)
    }
}

/// 趋势统计。
public struct MetricTrendStatistics: Hashable, Codable, Sendable {
    public let average: Double
    public let minimum: Double
    public let maximum: Double
    public let total: Double
    /// 有数据的天数。
    public let dayCount: Int

    public init?(points: [MetricDataPoint]) {
        guard !points.isEmpty else { return nil }
        let values = points.map(\.value)
        total = values.reduce(0, +)
        average = total / Double(values.count)
        minimum = points.map { $0.minimum ?? $0.value }.min()!
        maximum = points.map { $0.maximum ?? $0.value }.max()!
        dayCount = values.count
    }
}

/// 一项指标在某个时间范围内的趋势。
public struct MetricTrend: Hashable, Sendable {
    public let kind: HealthMetricKind
    public let period: TrendPeriod
    public let interval: DateInterval
    public let points: [MetricDataPoint]
    public let statistics: MetricTrendStatistics?

    public init(kind: HealthMetricKind, period: TrendPeriod, interval: DateInterval, points: [MetricDataPoint]) {
        self.kind = kind
        self.period = period
        self.interval = interval
        self.points = points.sorted { $0.date < $1.date }
        self.statistics = MetricTrendStatistics(points: points)
    }
}
