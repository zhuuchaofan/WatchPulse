import Foundation

/// 运动后反馈（v0.3 T3）的参数。全部为确定性规则，不随数据自动调整。
public struct WorkoutFeedbackConfiguration: Hashable, Sendable {
    /// 至少需要多少次可比的同类运动才做比较；不足时只展示本次数据。
    public var minimumSamples = 3
    /// 每项指标最多与最近多少次可比运动比较。
    public var maximumSamples = 5
    /// 只与本次之前这段时间内的运动比较（秒）。
    public var lookback: TimeInterval = 90 * 86_400
    /// 时长 / 距离 / 速度：相对差异在此比例以内视为“相近”。
    public var similarRelativeChange = 0.05
    /// 平均心率：相差在此次数/分以内视为“相近”。
    public var similarHeartRateDifference = 3.0
    /// 区间占比：相差在此比例（百分点 / 100）以内视为“相近”。
    public var similarZoneShare = 0.05
    public var comparability = WorkoutComparabilityConfiguration()

    public init() {}
}

/// 本次与对比平均值的关系。只描述数值高低，不评价好坏。
public enum WorkoutFeedbackDirection: String, Hashable, Codable, Sendable {
    case higher
    case lower
    case similar
}

/// 参与某项比较的对比对象：更早的、可比的同类运动。
public struct WorkoutFeedbackBaseline: Hashable, Sendable {
    /// 按开始时间倒序。
    public let workoutIDs: [UUID]
    public let earliestStart: Date
    public let latestStart: Date

    public var sampleCount: Int { workoutIDs.count }
}

/// 某项指标无法比较的原因。
public enum WorkoutFeedbackUnavailableReason: Hashable, Sendable {
    /// 本次没有该数据（显示 `--`，不补 0）。
    case noData
    /// 本次运动整体不参与比较（疑似重复、室内外未知等，见 `WorkoutFeedback.Status.notEligible`）。
    case workoutNotEligible
    /// 本次心率可信度不足以用于跨运动比较。
    case heartRateNotComparable(HeartRateUsability)
    /// 没有用户确认的个人心率区间（不推算最大心率）。
    case noPersonalZones

    public var message: String {
        switch self {
        case .noData: return "本次没有该数据"
        case .workoutNotEligible: return "本次运动不参与比较"
        case .heartRateNotComparable(let usability): return "本次心率\(usability.title)，不用于比较"
        case .noPersonalZones: return "未设置个人心率区间，不比较区间分布"
        }
    }
}

/// 单项指标的比较结果。
public struct WorkoutMetricFeedback: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// `difference` = 本次 − 平均；`relativeChange` = 差值 ÷ 平均。
        case compared(baselineAverage: Double, difference: Double, relativeChange: Double, direction: WorkoutFeedbackDirection, baseline: WorkoutFeedbackBaseline)
        /// 可比样本不足：只展示本次数据，不下判断。
        case insufficientSamples(found: Int, required: Int)
        case unavailable(WorkoutFeedbackUnavailableReason)
    }

    public let metric: WorkoutMetric
    /// 本次的数值（时长：秒；距离：米；均速：米/秒；平均心率：次/分）。没有数据时为 `nil`。
    public let currentValue: Double?
    public let outcome: Outcome
}

/// 个人心率区间分布的比较：各区间时间占比（排除缺测）。键 0 表示低于 Z1 下限，1…5 为 Z1…Z5。
public struct WorkoutZoneFeedback: Hashable, Sendable {
    public struct Row: Hashable, Sendable {
        public let zone: Int
        public let currentShare: Double
        /// 对比运动的平均占比；未比较时为 `nil`。
        public let baselineShare: Double?
        public let direction: WorkoutFeedbackDirection?
    }

    public enum Outcome: Hashable, Sendable {
        case compared(baseline: WorkoutFeedbackBaseline)
        case insufficientSamples(found: Int, required: Int)
        case unavailable(WorkoutFeedbackUnavailableReason)
    }

    /// 区间口径（个人区间，标注最大心率与来源）；没有个人区间分布时为 `nil`。
    public let basis: HeartRateZoneBasis?
    /// 本次分布（有个人区间分布时总是给出，即使不比较）。
    public let rows: [Row]
    public let outcome: Outcome
}

/// 未纳入比较的同类运动的一个原因及次数。
public struct WorkoutFeedbackExclusion: Hashable, Sendable {
    public let reason: WorkoutComparabilityReason
    public let count: Int
}

/// 一次运动的运动后反馈：与自己最近的可比同类运动比较。
///
/// 规则（路线图 v0.3 T3）：
/// - 对比对象只来自 `WorkoutComparability` 判定可比的、本次之前 `lookback` 内的运动，每项指标取最近 `maximumSamples` 次；
/// - 每项结论附带对比对象与样本数；某项可比样本少于 `minimumSamples` 时该项不下判断；
/// - 只描述“比平均高 / 低 / 相近”，不评价进步或退步，不做健康判断。
public struct WorkoutFeedback: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        /// 至少有一项指标完成了比较。
        case compared
        /// 可比的同类运动不足，只展示本次数据。`found` 为时间窗内可比运动的次数。
        case insufficientSamples(found: Int, required: Int)
        /// 本次运动不满足进步比较资格。
        case notEligible([WorkoutAnalysisBlocker])
    }

    public let workoutID: UUID
    public let activity: WorkoutActivityKind
    public let location: WorkoutLocation
    public let status: Status
    /// 按 时长 → 距离 → 均速 → 平均心率 排列；本类运动不记录距离时不含距离与均速。
    public let metrics: [WorkoutMetricFeedback]
    public let zones: WorkoutZoneFeedback
    /// 时间窗内可比的同类运动总数（比较时每项最多取最近 `maximumSamples` 次）。
    public let comparableCount: Int
    /// 时间窗内同类型、但不可比而未纳入的运动次数。
    public let excludedCount: Int
    /// 未纳入的原因及次数（一次运动可有多个原因），按次数降序。
    public let exclusions: [WorkoutFeedbackExclusion]
    /// 对比对象的附加说明（如双方都未记录设备）。
    public let caveats: [WorkoutComparabilityCaveat]
    public let configuration: WorkoutFeedbackConfiguration

    public func metric(_ metric: WorkoutMetric) -> WorkoutMetricFeedback? {
        metrics.first { $0.metric == metric }
    }
}

public enum WorkoutFeedbackCalculator {
    /// 比较的标量指标（相同心率下的速度属于 T4 进步分析，这里不做）。
    static let scalarMetrics: [WorkoutMetric] = [.duration, .distance, .averageSpeed, .averageHeartRate]

    /// 计算 `target` 的运动后反馈。`records` 为同一分析集合中的其他记录（可以包含 `target` 本身，会被忽略）。
    public static func feedback(
        for target: WorkoutAnalysisRecord,
        among records: [WorkoutAnalysisRecord],
        configuration: WorkoutFeedbackConfiguration = .init()
    ) -> WorkoutFeedback {
        let required = max(1, configuration.minimumSamples)
        let windowStart = target.workout.startDate.addingTimeInterval(-configuration.lookback)
        let candidates = records
            .filter { $0.id != target.id && $0.workout.activity == target.workout.activity }
            .filter { $0.workout.startDate < target.workout.startDate && $0.workout.startDate >= windowStart }
            // 同一时刻开始的按 ID 排序，保证结果与输入顺序无关。
            .sorted { ($0.workout.startDate, $0.id.uuidString) > ($1.workout.startDate, $1.id.uuidString) }

        let eligible = target.eligibility.canCompareProgress
        var comparable: [(record: WorkoutAnalysisRecord, metrics: Set<WorkoutMetric>)] = []
        var caveats: [WorkoutComparabilityCaveat] = []
        var reasonCounts: [WorkoutComparabilityReason: Int] = [:]
        var excluded = 0
        if eligible {
            for candidate in candidates {
                switch WorkoutComparability.compare(target, candidate, configuration: configuration.comparability) {
                case .comparable(let metrics, let notes):
                    comparable.append((candidate, metrics))
                    for note in notes where !caveats.contains(note) { caveats.append(note) }
                case .notComparable(let reasons):
                    excluded += 1
                    for reason in reasons { reasonCounts[reason, default: 0] += 1 }
                }
            }
        }

        func baseline(for metric: WorkoutMetric) -> [WorkoutAnalysisRecord] {
            Array(comparable.filter { $0.metrics.contains(metric) }.prefix(configuration.maximumSamples).map { $0.record })
        }

        var metrics: [WorkoutMetricFeedback] = []
        for metric in scalarMetrics {
            if metric == .distance || metric == .averageSpeed, target.completeness.distance == .notApplicable { continue }
            let current = value(of: metric, in: target)
            let outcome: WorkoutMetricFeedback.Outcome
            if current == nil {
                outcome = .unavailable(.noData)
            } else if !eligible {
                outcome = .unavailable(.workoutNotEligible)
            } else if !target.eligibility.progressMetrics.contains(metric) {
                outcome = metric == .averageHeartRate
                    ? .unavailable(.heartRateNotComparable(target.heartRate.usability))
                    : .unavailable(.noData)
            } else {
                let samples = baseline(for: metric)
                let values = samples.compactMap { value(of: metric, in: $0) }
                if values.count < required || values.count != samples.count {
                    outcome = .insufficientSamples(found: values.count, required: required)
                } else {
                    let average = values.reduce(0, +) / Double(values.count)
                    let difference = current! - average
                    let relative = average > 0 ? difference / average : 0
                    let similar = metric == .averageHeartRate
                        ? abs(difference) < configuration.similarHeartRateDifference
                        : abs(relative) < configuration.similarRelativeChange
                    outcome = .compared(
                        baselineAverage: average,
                        difference: difference,
                        relativeChange: relative,
                        direction: similar ? .similar : (difference > 0 ? .higher : .lower),
                        baseline: makeBaseline(samples)
                    )
                }
            }
            metrics.append(WorkoutMetricFeedback(metric: metric, currentValue: current, outcome: outcome))
        }

        let zones = zoneFeedback(target: target, eligible: eligible, samples: baseline(for: .heartRateZoneDistribution), required: required, configuration: configuration)

        let status: WorkoutFeedback.Status
        if !eligible {
            status = .notEligible(target.eligibility.blockers)
        } else if metrics.contains(where: { if case .compared = $0.outcome { return true } else { return false } }) {
            status = .compared
        } else {
            status = .insufficientSamples(found: comparable.count, required: required)
        }

        return WorkoutFeedback(
            workoutID: target.id,
            activity: target.workout.activity,
            location: target.workout.location,
            status: status,
            metrics: metrics,
            zones: zones,
            comparableCount: comparable.count,
            excludedCount: excluded,
            exclusions: reasonCounts
                .map { WorkoutFeedbackExclusion(reason: $0.key, count: $0.value) }
                .sorted { ($0.count, $1.reason.rawValue) > ($1.count, $0.reason.rawValue) },
            caveats: caveats,
            configuration: configuration
        )
    }

    /// 指标数值；缺失或无效时为 `nil`。
    static func value(of metric: WorkoutMetric, in record: WorkoutAnalysisRecord) -> Double? {
        let workout = record.workout
        switch metric {
        case .duration:
            return WorkoutAnalysisBuilder.hasValidTimeRange(workout) ? workout.duration : nil
        case .distance:
            return WorkoutAnalysisBuilder.hasDistance(workout) ? workout.distanceMeters : nil
        case .averageSpeed:
            guard WorkoutAnalysisBuilder.hasDistance(workout) else { return nil }
            return WorkoutSpeedMath.averageSpeed(distanceMeters: workout.distanceMeters, activeDuration: workout.duration)
        case .averageHeartRate:
            // 使用清洗后的有效样本均值；没有读取到曲线时退回运动记录自带的平均心率（仅展示，比较资格另行判定）。
            let value = record.heartRate.statistics?.average ?? workout.averageHeartRate
            return value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        case .heartRateZoneDistribution, .speedAtHeartRate:
            return nil
        }
    }

    static func zoneShares(_ distribution: HeartRateZoneDistribution) -> [Int: Double]? {
        guard distribution.coveredDuration > 0 else { return nil }
        var shares: [Int: Double] = [0: distribution.belowRangeDuration / distribution.coveredDuration]
        for zone in 1...5 {
            shares[zone] = (distribution.durations[zone] ?? 0) / distribution.coveredDuration
        }
        return shares
    }

    private static func zoneFeedback(
        target: WorkoutAnalysisRecord,
        eligible: Bool,
        samples: [WorkoutAnalysisRecord],
        required: Int,
        configuration: WorkoutFeedbackConfiguration
    ) -> WorkoutZoneFeedback {
        guard let distribution = target.personalZones, let current = zoneShares(distribution) else {
            return WorkoutZoneFeedback(basis: nil, rows: [], outcome: .unavailable(target.personalZones == nil ? .noPersonalZones : .noData))
        }
        func rows(_ baseline: [Int: Double]?) -> [WorkoutZoneFeedback.Row] {
            (0...5).map { zone in
                let share = current[zone] ?? 0
                let base = baseline?[zone]
                let direction = base.map { base -> WorkoutFeedbackDirection in
                    let difference = share - base
                    if abs(difference) < configuration.similarZoneShare { return .similar }
                    return difference > 0 ? .higher : .lower
                }
                return WorkoutZoneFeedback.Row(zone: zone, currentShare: share, baselineShare: base, direction: direction)
            }
        }
        guard eligible else {
            return WorkoutZoneFeedback(basis: distribution.basis, rows: rows(nil), outcome: .unavailable(.workoutNotEligible))
        }
        guard target.eligibility.progressMetrics.contains(.heartRateZoneDistribution) else {
            return WorkoutZoneFeedback(basis: distribution.basis, rows: rows(nil), outcome: .unavailable(.heartRateNotComparable(target.heartRate.usability)))
        }
        let shares = samples.compactMap { $0.personalZones.flatMap(zoneShares) }
        guard shares.count >= required, shares.count == samples.count else {
            return WorkoutZoneFeedback(
                basis: distribution.basis, rows: rows(nil),
                outcome: .insufficientSamples(found: shares.count, required: required)
            )
        }
        var average: [Int: Double] = [:]
        for zone in 0...5 {
            average[zone] = shares.map { $0[zone] ?? 0 }.reduce(0, +) / Double(shares.count)
        }
        return WorkoutZoneFeedback(basis: distribution.basis, rows: rows(average), outcome: .compared(baseline: makeBaseline(samples)))
    }

    private static func makeBaseline(_ records: [WorkoutAnalysisRecord]) -> WorkoutFeedbackBaseline {
        let starts = records.map(\.workout.startDate)
        return WorkoutFeedbackBaseline(workoutIDs: records.map(\.id), earliestStart: starts.min()!, latestStart: starts.max()!)
    }
}
