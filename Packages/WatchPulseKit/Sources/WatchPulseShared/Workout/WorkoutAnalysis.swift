import Foundation

/// 可以在统计 / 进步比较中使用的指标。资格判定按指标给出，缺失或不可信的指标被排除，其余照常使用。
public enum WorkoutMetric: String, CaseIterable, Hashable, Codable, Sendable {
    case duration
    case distance
    case averageSpeed
    case averageHeartRate
    /// 个人心率区间分布（需用户确认的区间配置，且口径一致）。
    case heartRateZoneDistribution
    /// 相同心率下的速度 / 配速。
    case speedAtHeartRate
}

public enum WorkoutDataAvailability: String, Hashable, Codable, Sendable {
    case present
    /// 该类运动应有此数据，但缺失（显示 `--`，不补 0）。
    case missing
    /// 该类运动本来就没有此数据（例如 HIIT 没有距离）。
    case notApplicable
}

/// 数据完整度。缺失只影响具备该数据的那部分分析。
public struct WorkoutDataCompleteness: Hashable, Codable, Sendable {
    public let hasValidTimeRange: Bool
    public let distance: WorkoutDataAvailability
    public let heartRate: WorkoutDataAvailability
    public let energy: WorkoutDataAvailability
    public let locationKnown: Bool
}

/// 阻止某条记录进入统计 / 进步比较的原因。
public enum WorkoutAnalysisBlocker: String, Hashable, Codable, Sendable {
    case invalidTimeRange
    /// 与更优先的记录疑似重复，统计总量时已按一次计入，本条不计。
    case excludedAsSuspectedDuplicate
    /// 与其他记录疑似重复：本条可计入统计，但证据不确定，不参与进步比较。
    case suspectedDuplicate
    case locationUnknown

    public var message: String {
        switch self {
        case .invalidTimeRange: return "起止时间或时长无效"
        case .excludedAsSuspectedDuplicate: return "疑似与另一条记录重复，统计时按一次计入"
        case .suspectedDuplicate: return "疑似与另一条记录重复，不参与进步比较"
        case .locationUnknown: return "室内 / 室外未知，不参与进步比较"
        }
    }
}

/// 分析资格：哪些可以展示，哪些可以统计，哪些可以支持进步比较。
public struct WorkoutEligibility: Hashable, Codable, Sendable {
    /// 时间区间合法即可展示（路线图 1.3.1-D）。这只约束分析层；运动历史列表仍照常列出全部原始记录。
    public let canDisplay: Bool
    public let statisticsMetrics: Set<WorkoutMetric>
    public let progressMetrics: Set<WorkoutMetric>
    public let blockers: [WorkoutAnalysisBlocker]

    /// 可计入次数 / 时长 / 距离合计。
    public var canCountInStatistics: Bool { !statisticsMetrics.isEmpty }
    /// 至少有一项指标可用于进步比较。
    public var canCompareProgress: Bool { !progressMetrics.isEmpty }
}

/// 统一的运动分析记录：来源、类型、室内外、时长、距离、心率、数据完整度与归属可信度。
public struct WorkoutAnalysisRecord: Identifiable, Hashable, Sendable {
    /// 主记录（确认重复合并后选出的那条）。
    public let workout: WorkoutRecord
    public let origin: HealthDataOrigin
    /// 被合并的确认重复记录的来源，便于追溯。
    public let mergedSources: [WorkoutSourceInfo]
    /// 被合并的确认重复记录的 ID，用于从任一原始记录找到对应的主记录。
    public let mergedWorkoutIDs: [UUID]
    public let duplicateStatus: DeduplicatedWorkout.Status
    public let heartRate: HeartRateEvidence
    /// 用户配置了个人区间且存在有效心率时的区间分布；**没有用户确认的配置时为 `nil`，不推算最大心率**。
    public let personalZones: HeartRateZoneDistribution?
    public let completeness: WorkoutDataCompleteness
    public let eligibility: WorkoutEligibility

    public var id: UUID { workout.id }
    public var source: WorkoutSourceInfo { workout.source }
    public var isSimulated: Bool { origin.isSimulated }
}

public struct WorkoutAnalysisConfiguration: Hashable, Sendable {
    public var deduplication = WorkoutDeduplicationConfiguration()
    public var heartRate = HeartRateEvidenceConfiguration()
    public init() {}
}

public struct WorkoutAnalysisSet: Hashable, Sendable {
    public let origin: HealthDataOrigin
    /// 按开始时间倒序；**包含**被疑似重复排除统计的记录。
    public let records: [WorkoutAnalysisRecord]

    /// 原始运动 ID 对应的分析记录：主记录本身，或合并了该条确认重复记录的主记录。
    public func record(containing workoutID: UUID) -> WorkoutAnalysisRecord? {
        records.first { $0.id == workoutID } ?? records.first { $0.mergedWorkoutIDs.contains(workoutID) }
    }

    public var suspectedExcludedFromTotals: Int {
        records.filter { $0.eligibility.blockers.contains(.excludedAsSuspectedDuplicate) }.count
    }
}

public enum WorkoutAnalysisBuilder {
    /// 去重 → 心率可信度 → 区间 → 完整度 → 资格。
    public static func build(
        records: [WorkoutRecord],
        heartRates: [UUID: WorkoutHeartRateSeries],
        origin: HealthDataOrigin,
        zoneSettings: HeartRateZoneSettings?,
        configuration: WorkoutAnalysisConfiguration = .init()
    ) -> WorkoutAnalysisSet {
        let result = WorkoutDeduplicator.deduplicate(records, configuration: configuration.deduplication)
        return build(deduplication: result, heartRates: heartRates, origin: origin, zoneSettings: zoneSettings, configuration: configuration)
    }

    public static func build(
        deduplication: WorkoutDeduplicationResult,
        heartRates: [UUID: WorkoutHeartRateSeries],
        origin: HealthDataOrigin,
        zoneSettings: HeartRateZoneSettings?,
        configuration: WorkoutAnalysisConfiguration = .init()
    ) -> WorkoutAnalysisSet {
        let analysed = deduplication.entries.map { entry -> WorkoutAnalysisRecord in
            let workout = entry.primary
            let series = heartRates[workout.id]
            let evidence = HeartRateEvidence.evaluate(series, for: workout, configuration: configuration.heartRate)

            var zones: HeartRateZoneDistribution?
            if let settings = zoneSettings, let series, evidence.usability.allowsDisplay {
                let valid = HeartRateEvidence.validPoints(in: series.points, for: workout, configuration: configuration.heartRate)
                zones = HeartRateZoneAnalyzer.personal(points: valid, settings: settings, maximumGap: configuration.heartRate.maximumGap)
            }

            let completeness = completeness(of: workout, evidence: evidence)
            let eligibility = eligibility(of: workout, entry: entry, completeness: completeness, evidence: evidence, zones: zones)
            return WorkoutAnalysisRecord(
                workout: workout,
                origin: origin,
                mergedSources: entry.mergedDuplicates.map(\.source),
                mergedWorkoutIDs: entry.mergedDuplicates.map(\.id),
                duplicateStatus: entry.duplicateStatus,
                heartRate: evidence,
                personalZones: zones,
                completeness: completeness,
                eligibility: eligibility
            )
        }
        return WorkoutAnalysisSet(origin: origin, records: analysed)
    }

    static func hasValidTimeRange(_ workout: WorkoutRecord) -> Bool {
        workout.duration.isFinite && workout.duration > 0 && workout.endDate >= workout.startDate
    }

    static func hasDistance(_ workout: WorkoutRecord) -> Bool {
        guard let distance = workout.distanceMeters else { return false }
        return distance.isFinite && distance > 0
    }

    private static func completeness(of workout: WorkoutRecord, evidence: HeartRateEvidence) -> WorkoutDataCompleteness {
        let distance: WorkoutDataAvailability
        if hasDistance(workout) {
            distance = .present
        } else {
            distance = workout.activity.tracksDistance ? .missing : .notApplicable
        }
        let heartRate: WorkoutDataAvailability = evidence.usability != .unavailable || workout.averageHeartRate != nil ? .present : .missing
        return WorkoutDataCompleteness(
            hasValidTimeRange: hasValidTimeRange(workout),
            distance: distance,
            heartRate: heartRate,
            energy: workout.activeEnergyKilocalories != nil ? .present : .missing,
            locationKnown: workout.location != .unknown
        )
    }

    private static func eligibility(
        of workout: WorkoutRecord,
        entry: DeduplicatedWorkout,
        completeness: WorkoutDataCompleteness,
        evidence: HeartRateEvidence,
        zones: HeartRateZoneDistribution?
    ) -> WorkoutEligibility {
        var blockers: [WorkoutAnalysisBlocker] = []
        if !completeness.hasValidTimeRange { blockers.append(.invalidTimeRange) }
        if !entry.countsTowardTotals { blockers.append(.excludedAsSuspectedDuplicate) }
        if entry.countsTowardTotals, !entry.suspectedCounterparts.isEmpty { blockers.append(.suspectedDuplicate) }
        if !completeness.locationKnown { blockers.append(.locationUnknown) }

        let canCount = completeness.hasValidTimeRange && entry.countsTowardTotals
        let canCompare = canCount && entry.suspectedCounterparts.isEmpty && completeness.locationKnown
        let distance = completeness.distance == .present

        var statistics = Set<WorkoutMetric>()
        if canCount {
            statistics.insert(.duration)
            if distance { statistics.formUnion([.distance, .averageSpeed]) }
            if evidence.usability.allowsStatistics { statistics.insert(.averageHeartRate) }
        }

        var progress = Set<WorkoutMetric>()
        if canCompare {
            progress.insert(.duration)
            if distance { progress.formUnion([.distance, .averageSpeed]) }
            if evidence.usability.allowsPerformanceConclusions {
                progress.insert(.averageHeartRate)
                if distance { progress.insert(.speedAtHeartRate) }
                if zones != nil { progress.insert(.heartRateZoneDistribution) }
            }
        }
        return WorkoutEligibility(canDisplay: completeness.hasValidTimeRange, statisticsMetrics: statistics, progressMetrics: progress, blockers: blockers)
    }
}
