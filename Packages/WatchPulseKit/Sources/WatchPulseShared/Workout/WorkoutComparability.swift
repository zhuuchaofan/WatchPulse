import Foundation

public enum WorkoutComparabilityReason: String, Hashable, Codable, Sendable {
    case differentActivity
    case differentLocation
    /// 任一条不满足进步比较资格（疑似重复、室内外未知、时间无效等）。
    case notEligible
    case differentSource
    /// 同一来源但设备型号不同（传感器 / 算法可能不同）。
    case differentDevice
    /// 一方设备已知、另一方未知，无法确认是否同一设备族。
    case deviceUnknown
    case durationMismatch
    case distanceMismatch

    public var message: String {
        switch self {
        case .differentActivity: return "运动类型不同"
        case .differentLocation: return "室内 / 室外不同"
        case .notEligible: return "其中一次运动的数据不完整"
        case .differentSource: return "数据来源不同，记录方式可能不一致"
        case .differentDevice: return "记录设备不同"
        case .deviceUnknown: return "没有记录设备信息，无法确认是否可比"
        case .durationMismatch: return "时长相差过大"
        case .distanceMismatch: return "距离相差过大"
        }
    }
}

public enum WorkoutComparabilityCaveat: String, Hashable, Codable, Sendable {
    /// 双方都没有记录设备信息，只能按来源判断，无法发现设备更换。
    case deviceNotRecorded
}

public struct WorkoutComparabilityConfiguration: Hashable, Sendable {
    /// 距离 / 时长的最大比值（≥ 1）。
    public var maximumSizeRatio = 1.5
    public init() {}
}

public enum WorkoutComparability {
    public enum Verdict: Hashable, Sendable {
        /// 可比较，并给出可以用于对比的指标集合（双方都具备资格的交集）。
        case comparable(metrics: Set<WorkoutMetric>, caveats: [WorkoutComparabilityCaveat])
        case notComparable([WorkoutComparabilityReason])
    }

    public static func compare(
        _ a: WorkoutAnalysisRecord,
        _ b: WorkoutAnalysisRecord,
        configuration: WorkoutComparabilityConfiguration = .init()
    ) -> Verdict {
        guard a.workout.activity == b.workout.activity else { return .notComparable([.differentActivity]) }
        guard a.eligibility.canCompareProgress, b.eligibility.canCompareProgress else { return .notComparable([.notEligible]) }

        var reasons: [WorkoutComparabilityReason] = []
        var caveats: [WorkoutComparabilityCaveat] = []
        if a.workout.location != b.workout.location { reasons.append(.differentLocation) }
        if a.source.sourceKey != b.source.sourceKey { reasons.append(.differentSource) }

        switch (a.source.deviceFamilyKey, b.source.deviceFamilyKey) {
        case let (x?, y?): if x != y { reasons.append(.differentDevice) }
        case (nil, nil): caveats.append(.deviceNotRecorded)
        default: reasons.append(.deviceUnknown)
        }

        if let x = positiveDistance(a), let y = positiveDistance(b) {
            if ratio(x, y) > configuration.maximumSizeRatio { reasons.append(.distanceMismatch) }
        } else if ratio(a.workout.duration, b.workout.duration) > configuration.maximumSizeRatio {
            reasons.append(.durationMismatch)
        }
        guard reasons.isEmpty else { return .notComparable(reasons) }

        var metrics = a.eligibility.progressMetrics.intersection(b.eligibility.progressMetrics)
        if let x = a.personalZones?.basis, let y = b.personalZones?.basis, !x.isComparable(with: y) {
            metrics.remove(.heartRateZoneDistribution)
        }
        return .comparable(metrics: metrics, caveats: caveats)
    }

    /// 与 `target` 可比的其他运动，按开始时间倒序。`onlyBefore` 时只取更早的。
    public static func comparableWorkouts(
        to target: WorkoutAnalysisRecord,
        in candidates: [WorkoutAnalysisRecord],
        onlyBefore: Bool = false,
        configuration: WorkoutComparabilityConfiguration = .init()
    ) -> [WorkoutAnalysisRecord] {
        candidates
            .filter { $0.id != target.id }
            .filter { !onlyBefore || $0.workout.startDate < target.workout.startDate }
            .filter { if case .comparable = compare(target, $0, configuration: configuration) { return true } else { return false } }
            .sorted { $0.workout.startDate > $1.workout.startDate }
    }

    private static func positiveDistance(_ record: WorkoutAnalysisRecord) -> Double? {
        record.eligibility.progressMetrics.contains(.distance) ? record.workout.distanceMeters : nil
    }

    private static func ratio(_ x: Double, _ y: Double) -> Double {
        guard x > 0, y > 0 else { return .infinity }
        return max(x, y) / min(x, y)
    }
}
