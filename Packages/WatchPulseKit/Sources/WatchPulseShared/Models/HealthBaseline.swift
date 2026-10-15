import Foundation

/// 某一天的指标值；`value == nil` 表示当天没有数据（缺测），而不是 0。
public struct DailyMetricValue: Hashable, Sendable, Identifiable {
    /// 当天零点（本地日历）。
    public let date: Date
    public let value: Double?

    public var id: Date { date }

    public init(date: Date, value: Double?) {
        self.date = date
        self.value = value
    }
}

/// “每天一个数据点”的序列：区间内每个日历日都有一项，缺测日明确标出。
///
/// 按 `Calendar` 逐日推进（不是按 86400 秒），因此夏令时切换日（23 / 25 小时）不会重复或缺失。
public struct DailyMetricSeries: Hashable, Sendable {
    public let kind: HealthMetricKind
    public let interval: DateInterval
    public let days: [DailyMetricValue]

    public init(kind: HealthMetricKind, points: [MetricDataPoint], interval: DateInterval, calendar: Calendar = .current) {
        self.kind = kind
        self.interval = interval
        var byDay: [Date: Double] = [:]
        for point in points where point.value.isFinite {
            byDay[calendar.startOfDay(for: point.date)] = point.value
        }
        var days: [DailyMetricValue] = []
        var day = calendar.startOfDay(for: interval.start)
        while day < interval.end {
            days.append(DailyMetricValue(date: day, value: byDay[day]))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        self.days = days
    }

    /// 有数据的天。
    public var validDays: [DailyMetricValue] { days.filter { $0.value != nil } }
    public var validDayCount: Int { validDays.count }
    public var missingDayCount: Int { days.count - validDayCount }
    /// 最近一个有数据的日期。
    public var latestDate: Date? { validDays.last?.date }

    /// 某个子区间内的有效值。
    public func values(in interval: DateInterval) -> [Double] {
        days.filter { $0.date >= interval.start && $0.date < interval.end }.compactMap(\.value)
    }

    /// 截至 `now` 最近一次数据距今几天（今天为 0）；没有数据为 `nil`。
    public func daysSinceLatest(asOf now: Date, calendar: Calendar = .current) -> Int? {
        guard let latestDate else { return nil }
        return calendar.dateComponents([.day], from: latestDate, to: calendar.startOfDay(for: now)).day
    }
}

/// 个人基线的时间窗口：观察期为截至昨天的最近 7 个**完整**日（不含今天），参考期为观察期之前连续 28 天。
public struct BaselineWindows: Hashable, Sendable {
    public let observation: DateInterval
    public let reference: DateInterval

    public static let observationDays = 7
    public static let referenceDays = 28

    public init(asOf now: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let observationStart = calendar.date(byAdding: .day, value: -Self.observationDays, to: today)!
        let referenceStart = calendar.date(byAdding: .day, value: -Self.referenceDays, to: observationStart)!
        observation = DateInterval(start: observationStart, end: today)
        reference = DateInterval(start: referenceStart, end: observationStart)
    }

    /// 需要查询的完整区间（参考期开始至今天零点）。
    public var fullInterval: DateInterval {
        DateInterval(start: reference.start, end: observation.end)
    }
}

/// 数据是否足以给出基线比较。
public enum BaselineSufficiency: Hashable, Sendable {
    case sufficient
    /// 有效天数不足：显示“积累中（x/y 天）”，不计算差值。
    case insufficient(referenceDays: Int, observationDays: Int)
}

/// 近 7 天与此前 28 天（个人基线）的比较。只描述数值变化，不做任何健康判断。
public struct BaselineComparison: Hashable, Sendable {
    public enum Direction: Hashable, Sendable {
        case up
        case down
        case flat
    }

    public let kind: HealthMetricKind
    public let windows: BaselineWindows
    /// 观察期有效日值的中位数。
    public let observationMedian: Double?
    /// 参考期有效日值的中位数（个人基线）。
    public let referenceMedian: Double?
    public let observationDays: Int
    public let referenceDays: Int
    /// 因超出合理范围被排除的日值个数。
    public let excludedDays: Int
    public let sufficiency: BaselineSufficiency

    public static let minimumReferenceDays = 14
    public static let minimumObservationDays = 4

    /// 观察期中位数 − 基线；数据不足时为 `nil`。
    public var delta: Double? {
        guard sufficiency == .sufficient, let observationMedian, let referenceMedian else { return nil }
        return observationMedian - referenceMedian
    }

    /// 变化方向；小于 `kind` 的最小有意义差值视为持平（仅为显示取整，不代表临床意义）。
    public var direction: Direction? {
        guard let delta else { return nil }
        if abs(delta) < Self.flatThreshold(for: kind) { return .flat }
        return delta > 0 ? .up : .down
    }

    public init(kind: HealthMetricKind, daily: DailyMetricSeries, windows: BaselineWindows) {
        self.kind = kind
        self.windows = windows
        let range = Self.plausibleRange(for: kind)
        let referenceAll = daily.values(in: windows.reference)
        let observationAll = daily.values(in: windows.observation)
        let reference = referenceAll.filter { range.contains($0) }
        let observation = observationAll.filter { range.contains($0) }
        excludedDays = (referenceAll.count - reference.count) + (observationAll.count - observation.count)
        referenceDays = reference.count
        observationDays = observation.count
        referenceMedian = Self.median(reference)
        observationMedian = Self.median(observation)
        if referenceDays >= Self.minimumReferenceDays, observationDays >= Self.minimumObservationDays {
            sufficiency = .sufficient
        } else {
            sufficiency = .insufficient(referenceDays: referenceDays, observationDays: observationDays)
        }
    }

    /// 中位数（偶数个取中间两数平均）；空数组为 `nil`。
    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// 日值的合理范围，超出视为异常数据（例如录入错误），不参与基线。
    public static func plausibleRange(for kind: HealthMetricKind) -> ClosedRange<Double> {
        switch kind {
        case .restingHeartRate: return 25...200
        case .heartRateVariability: return 1...300
        case .heartRate: return 25...250
        case .stepCount: return 0...200_000
        case .activeEnergy: return 0...10_000
        case .sleep: return 0...24
        }
    }

    static func flatThreshold(for kind: HealthMetricKind) -> Double {
        switch kind {
        case .restingHeartRate, .heartRate: return 1
        case .heartRateVariability: return 1
        case .stepCount: return 100
        case .activeEnergy: return 10
        case .sleep: return 0.1
        }
    }
}

extension BaselineComparison {
    /// 例如“较基线 −3”“与基线持平”“积累中（9/14 天）”。
    public var shortText: String {
        switch sufficiency {
        case .insufficient(let referenceDays, let observationDays):
            if referenceDays < Self.minimumReferenceDays {
                return "基线积累中（\(referenceDays)/\(Self.minimumReferenceDays) 天）"
            }
            return "近期数据不足（\(observationDays)/\(Self.minimumObservationDays) 天）"
        case .sufficient:
            guard let delta, let direction else { return "" }
            if direction == .flat { return "与基线持平" }
            let rounded = Int(delta.rounded())
            return "较基线 \(rounded > 0 ? "+" : "−")\(abs(rounded))"
        }
    }

    /// 完整说明（不含任何健康结论）。
    public var detailText: String {
        let unit = kind.unitLabel
        switch sufficiency {
        case .insufficient(let referenceDays, let observationDays):
            return "需要此前 28 天中至少 \(Self.minimumReferenceDays) 天、近 7 天中至少 \(Self.minimumObservationDays) 天有数据；当前分别为 \(referenceDays) 天、\(observationDays) 天。"
        case .sufficient:
            guard let observationMedian, let referenceMedian, let direction else { return "" }
            let observed = "近 7 天中位数 \(kind.formattedValue(observationMedian)) \(unit)"
            let baseline = "基线（此前 28 天中位数）\(kind.formattedValue(referenceMedian)) \(unit)"
            let change: String
            switch direction {
            case .flat: change = "两者基本持平"
            case .up: change = "高 \(kind.formattedValue(abs(delta ?? 0))) \(unit)"
            case .down: change = "低 \(kind.formattedValue(abs(delta ?? 0))) \(unit)"
            }
            return "\(observed)，\(baseline)，\(change)。样本：近期 \(observationDays) 天、基线 \(referenceDays) 天。"
        }
    }

    /// 所有基线文案共用的说明。
    public static let disclaimer = "这里只是把你近期的数据与你自己过去的数据做比较，不代表医疗诊断，也不能判断身体状况。"
}
