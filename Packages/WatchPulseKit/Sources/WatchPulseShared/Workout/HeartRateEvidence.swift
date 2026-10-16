import Foundation

/// 一次运动的心率数据可用级别（由低到高）。
///
/// “可展示”不等于“可统计”，“可统计”不等于“可比较”：
/// - `displayOnly`：只能展示曲线与数值（并说明原因），不进入汇总统计，不支持任何表现结论；
/// - `summary`：可计入平均心率等汇总，附带说明，不用于跨运动比较；
/// - `comparable`：归属可靠、覆盖充分，可用于“相同心率下的速度”“区间分布对比”等表现结论。
public enum HeartRateUsability: Int, Hashable, Codable, Comparable, Sendable {
    case unavailable = 0
    case displayOnly
    case summary
    case comparable

    public static func < (lhs: HeartRateUsability, rhs: HeartRateUsability) -> Bool { lhs.rawValue < rhs.rawValue }

    public var allowsDisplay: Bool { self >= .displayOnly }
    public var allowsStatistics: Bool { self >= .summary }
    public var allowsPerformanceConclusions: Bool { self == .comparable }
}

/// 心率可用级别被限制的原因（可同时有多个）。
public enum HeartRateIssue: String, Hashable, Codable, Sendable {
    case noSamples
    /// 仅按时间读取了所有来源的样本，可能混入其他设备。
    case attributionAllSources
    /// 同设备同时间段的样本（运动没有关联样本），需标注。
    case attributionSameDeviceTimeRange
    case lowCoverage
    case partialCoverage
    case tooFewSamples
    case manyAnomalies
    /// 没有读取到心率数据（未请求或读取失败）。
    case notLoaded

    public var message: String {
        switch self {
        case .noSamples: return "没有心率记录"
        case .attributionAllSources: return "心率按运动时间段读取，可能包含其他设备的数据"
        case .attributionSameDeviceTimeRange: return "心率来自同一设备在运动时间段内的记录，没有直接附在这次运动上"
        case .lowCoverage: return "运动中大部分时间没有心率记录"
        case .partialCoverage: return "运动中有一部分时间没有心率记录"
        case .tooFewSamples: return "心率记录点太少"
        case .manyAnomalies: return "心率中有较多明显异常的数值"
        case .notLoaded: return "心率数据没有读取成功"
        }
    }
}

public struct HeartRateEvidenceConfiguration: Hashable, Sendable {
    /// 合理的心率范围（次/分）。范围外与非有限值为异常样本。
    public var plausibleRange: ClosedRange<Double> = 30...230
    /// 相邻样本间隔超过它视为缺测（与运动详情的区间时长口径一致）。
    public var maximumGap: TimeInterval = 60
    /// 样本时间戳超出运动窗口的容差（秒）。
    public var windowTolerance: TimeInterval = 5
    public var minimumSamples = 12
    public var summaryCoverage = 0.6
    public var comparableCoverage = 0.8
    /// 异常样本占比：超过则只能展示 / 不可比较。
    public var displayOnlyAnomalyFraction = 0.10
    public var comparableAnomalyFraction = 0.05
    /// 是否允许“同设备时间段”样本用于表现比较。默认 `false`：未与运动直接关联。
    public var allowSameDeviceForComparison = false

    public init() {}
}

/// 心率数据的归属可信度评估结果。
public struct HeartRateEvidence: Hashable, Codable, Sendable {
    public let attribution: HeartRateAttribution?
    public let rawSampleCount: Int
    public let validSampleCount: Int
    public let anomalousSampleCount: Int
    /// 有效采样覆盖率（0…1）：样本间隔 ≤ 缺测阈值的累计时长 ÷ 运动时长。
    public let coverage: Double
    public let usability: HeartRateUsability
    public let reasons: [HeartRateIssue]
    /// 仅由有效样本计算的统计。
    public let statistics: HeartRateSeriesStatistics?

    public var anomalyFraction: Double {
        rawSampleCount > 0 ? Double(anomalousSampleCount) / Double(rawSampleCount) : 0
    }

    public static func unavailable(reason: HeartRateIssue) -> HeartRateEvidence {
        HeartRateEvidence(
            attribution: nil, rawSampleCount: 0, validSampleCount: 0, anomalousSampleCount: 0,
            coverage: 0, usability: .unavailable, reasons: [reason], statistics: nil
        )
    }

    /// 评估一次运动的心率。`series` 为 `nil` 表示没有读取（未请求 / 失败）。
    public static func evaluate(
        _ series: WorkoutHeartRateSeries?,
        for workout: WorkoutRecord,
        configuration: HeartRateEvidenceConfiguration = .init()
    ) -> HeartRateEvidence {
        guard let series else { return .unavailable(reason: .notLoaded) }

        // 1. 清洗：非有限 / 超范围 / 窗口外 / 重复时间戳 → 异常（排除并计数，不修正）。
        let valid = validPoints(in: series.points, for: workout, configuration: configuration)
        let raw = series.points.count
        let anomalous = raw - valid.count
        guard !valid.isEmpty else {
            return HeartRateEvidence(
                attribution: series.attribution, rawSampleCount: raw, validSampleCount: 0, anomalousSampleCount: anomalous,
                coverage: 0, usability: .unavailable, reasons: [.noSamples], statistics: nil
            )
        }

        // 2. 覆盖率。
        var covered: TimeInterval = 0
        for (current, next) in zip(valid, valid.dropFirst()) {
            let gap = next.date.timeIntervalSince(current.date)
            if gap > 0, gap <= configuration.maximumGap { covered += gap }
        }
        let coverage = min(1, covered / max(workout.duration, 1))
        let anomalyFraction = Double(anomalous) / Double(raw)

        // 3. 级别：从最宽松到最严格逐层降级，并记录全部原因。
        var reasons: [HeartRateIssue] = []
        var ceiling = HeartRateUsability.comparable

        switch series.attribution {
        case .workoutAssociated:
            break
        case .sameDevice:
            reasons.append(.attributionSameDeviceTimeRange)
            if !configuration.allowSameDeviceForComparison { ceiling = min(ceiling, .summary) }
        case .timeRangeAllSources:
            reasons.append(.attributionAllSources)
            ceiling = min(ceiling, .displayOnly)
        }
        if coverage < configuration.summaryCoverage {
            reasons.append(.lowCoverage)
            ceiling = min(ceiling, .displayOnly)
        } else if coverage < configuration.comparableCoverage {
            reasons.append(.partialCoverage)
            ceiling = min(ceiling, .summary)
        }
        if valid.count < configuration.minimumSamples {
            reasons.append(.tooFewSamples)
            ceiling = min(ceiling, .displayOnly)
        }
        if anomalyFraction > configuration.displayOnlyAnomalyFraction {
            reasons.append(.manyAnomalies)
            ceiling = min(ceiling, .displayOnly)
        } else if anomalyFraction > configuration.comparableAnomalyFraction {
            reasons.append(.manyAnomalies)
            ceiling = min(ceiling, .summary)
        }

        return HeartRateEvidence(
            attribution: series.attribution,
            rawSampleCount: raw,
            validSampleCount: valid.count,
            anomalousSampleCount: anomalous,
            coverage: coverage,
            usability: ceiling,
            reasons: reasons,
            statistics: HeartRateSeriesStatistics(points: valid)
        )
    }

    /// 通过清洗的有效样本（按时间升序）。区间分布等派生计算应使用它，而不是原始样本。
    public static func validPoints(
        in points: [HeartRatePoint],
        for workout: WorkoutRecord,
        configuration: HeartRateEvidenceConfiguration = .init()
    ) -> [HeartRatePoint] {
        let windowStart = workout.startDate.addingTimeInterval(-configuration.windowTolerance)
        let windowEnd = workout.endDate.addingTimeInterval(configuration.windowTolerance)
        // 同一时刻有多个样本时的取舍必须与输入顺序无关：按时间、再按（有限的）数值排序。
        func sortValue(_ point: HeartRatePoint) -> Double { point.beatsPerMinute.isFinite ? point.beatsPerMinute : -1 }
        var valid: [HeartRatePoint] = []
        var seen = Set<Date>()
        for point in points.sorted(by: { ($0.date, sortValue($0)) < ($1.date, sortValue($1)) }) {
            let isValidValue = point.beatsPerMinute.isFinite && configuration.plausibleRange.contains(point.beatsPerMinute)
            let inWindow = point.date >= windowStart && point.date <= windowEnd
            guard isValidValue, inWindow, seen.insert(point.date).inserted else { continue }
            valid.append(point)
        }
        return valid
    }
}
