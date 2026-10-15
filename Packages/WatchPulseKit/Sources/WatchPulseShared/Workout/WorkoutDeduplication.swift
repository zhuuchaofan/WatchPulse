import Foundation

/// 两条运动记录之间的重复关系。
public enum WorkoutDuplicateRelation: Hashable, Sendable {
    case confirmed(ConfirmedBasis)
    case suspected
    case independent

    /// 确认重复的依据，全部是确定性的可靠标识，不是单纯的时间重叠。
    public enum ConfirmedBasis: Hashable, Sendable {
        /// 同一个 `HKWorkout` UUID。
        case sameWorkoutIdentifier
        /// 相同的外部标识 / 同步标识。
        case sameExternalIdentifier
        /// 同一物理设备、不同来源、起止几乎完全一致。
        case sameDeviceSameWindow
    }
}

/// 重复检测的阈值。
public struct WorkoutDeduplicationConfiguration: Hashable, Sendable {
    /// 确认重复（同设备）要求的起止时间容差（秒）。
    public var confirmedTimeTolerance: TimeInterval = 2
    /// 确认重复要求的距离相对容差。
    public var confirmedDistanceTolerance: Double = 0.02
    /// 疑似重复：起止时间各自允许的最大偏差（秒）。
    public var suspectedBoundaryTolerance: TimeInterval = 300
    /// 疑似重复：时间交集 ÷ 并集的最小值，避免“短运动嵌在长运动里”被误判。
    public var suspectedMinimumOverlapRatio: Double = 0.7
    /// 疑似重复：距离相对容差；超过则视为不同的运动。
    public var suspectedDistanceTolerance: Double = 0.10

    public init() {}
}

/// 成对关系判定。**从不**仅凭“时间重叠 + 类型相同”判定重复。
public enum WorkoutDuplicateDetector {
    public static func relation(
        _ a: WorkoutRecord,
        _ b: WorkoutRecord,
        configuration: WorkoutDeduplicationConfiguration = .init()
    ) -> WorkoutDuplicateRelation {
        // 1. 同一个对象。
        if a.id == b.id { return .confirmed(.sameWorkoutIdentifier) }
        guard a.activity == b.activity else { return .independent }

        // 2. 可靠的外部标识。
        if !Set(a.source.duplicateKeys).isDisjoint(with: b.source.duplicateKeys) {
            return .confirmed(.sameExternalIdentifier)
        }

        // 3. 以下只有“不同来源”才可能重复；同来源的两条记录没有可靠标识就无法断定。
        guard a.source.sourceKey != b.source.sourceKey else { return .independent }
        guard locationsCompatible(a.location, b.location) else { return .independent }
        guard let distanceDelta = relativeDistanceDelta(a, b, tolerance: configuration.suspectedDistanceTolerance) else {
            return .independent
        }

        let startDelta = abs(a.startDate.timeIntervalSince(b.startDate))
        let endDelta = abs(a.endDate.timeIntervalSince(b.endDate))

        if let deviceA = a.source.deviceKey, deviceA == b.source.deviceKey,
           startDelta <= configuration.confirmedTimeTolerance,
           endDelta <= configuration.confirmedTimeTolerance,
           distanceDelta <= configuration.confirmedDistanceTolerance {
            return .confirmed(.sameDeviceSameWindow)
        }

        guard startDelta <= configuration.suspectedBoundaryTolerance,
              endDelta <= configuration.suspectedBoundaryTolerance,
              overlapRatio(a, b) >= configuration.suspectedMinimumOverlapRatio else {
            return .independent
        }
        return .suspected
    }

    /// 室内外都已知且不同才冲突；未知不构成否定证据。
    private static func locationsCompatible(_ a: WorkoutLocation, _ b: WorkoutLocation) -> Bool {
        a == .unknown || b == .unknown || a == b
    }

    /// 距离相对差；任一方缺失返回 0（缺失不是否定证据）；差异超过容差返回 `nil`（视为不同运动）。
    private static func relativeDistanceDelta(_ a: WorkoutRecord, _ b: WorkoutRecord, tolerance: Double) -> Double? {
        guard let x = a.distanceMeters, let y = b.distanceMeters, x > 0, y > 0 else { return 0 }
        let delta = abs(x - y) / max(x, y)
        return delta <= tolerance ? delta : nil
    }

    /// 时间交集 ÷ 并集。
    private static func overlapRatio(_ a: WorkoutRecord, _ b: WorkoutRecord) -> Double {
        let start = max(a.startDate, b.startDate)
        let end = min(a.endDate, b.endDate)
        let intersection = max(0, end.timeIntervalSince(start))
        let union = max(a.endDate, b.endDate).timeIntervalSince(min(a.startDate, b.startDate))
        return union > 0 ? intersection / union : 0
    }
}

/// 去重后的一条运动（一个或多个原始记录）。
public struct DeduplicatedWorkout: Identifiable, Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case unique
        /// 已按确认重复合并了 `count` 条其他记录（保留在 `mergedDuplicates`）。
        case confirmedMerged(count: Int)
        /// 与其他记录疑似重复：两条都保留，统计时按 `countsTowardTotals` 决定是否计入。
        case suspected(counterparts: [UUID])
    }

    public let primary: WorkoutRecord
    /// 被合并的确认重复记录（来源信息保留，便于追溯）。
    public let mergedDuplicates: [WorkoutRecord]
    /// 与之疑似重复的其他条目的主记录 ID。
    public let suspectedCounterparts: [UUID]
    /// 统计总量（次数 / 时长 / 距离）时是否计入；被更优先的疑似重复条目“顶替”的条目为 `false`。
    public let countsTowardTotals: Bool

    public var id: UUID { primary.id }

    public var duplicateStatus: Status {
        if !suspectedCounterparts.isEmpty { return .suspected(counterparts: suspectedCounterparts) }
        if !mergedDuplicates.isEmpty { return .confirmedMerged(count: mergedDuplicates.count) }
        return .unique
    }
}

public struct WorkoutDeduplicationResult: Hashable, Sendable {
    /// 按开始时间倒序。**不丢弃任何疑似重复条目。**
    public let entries: [DeduplicatedWorkout]

    /// 因疑似重复而不计入统计总量的条目数。
    public var suspectedExcludedFromTotals: Int {
        entries.filter { !$0.countsTowardTotals }.count
    }

    /// 参与疑似重复的条目数（含被计入的那一条）。
    public var suspectedEntryCount: Int {
        entries.filter { !$0.suspectedCounterparts.isEmpty }.count
    }
}

public enum WorkoutDeduplicator {
    /// 对记录分组。结果与输入顺序无关。
    public static func deduplicate(
        _ records: [WorkoutRecord],
        configuration: WorkoutDeduplicationConfiguration = .init()
    ) -> WorkoutDeduplicationResult {
        let sorted = records.sorted(by: stableOrder)
        var union = UnionFind(count: sorted.count)
        var suspectedPairs: [(Int, Int)] = []

        // 外部标识 / 同一 UUID：用字典，不受时间窗口限制。
        var byKey: [String: Int] = [:]
        for (index, record) in sorted.enumerated() {
            for key in ["id:\(record.id.uuidString)"] + record.source.duplicateKeys.map({ "\(record.activity.rawValue)|\($0)" }) {
                if let first = byKey[key] { union.merge(first, index) } else { byKey[key] = index }
            }
        }

        // 其余关系：按开始时间扫描窗口内的候选。
        let byStart = sorted.indices.sorted { sorted[$0].startDate < sorted[$1].startDate }
        for (position, i) in byStart.enumerated() {
            for j in byStart[(position + 1)...] {
                if sorted[j].startDate.timeIntervalSince(sorted[i].startDate) > configuration.suspectedBoundaryTolerance { break }
                switch WorkoutDuplicateDetector.relation(sorted[i], sorted[j], configuration: configuration) {
                case .confirmed: union.merge(i, j)
                case .suspected: suspectedPairs.append((i, j))
                case .independent: break
                }
            }
        }

        // 确认重复分组 → 主记录。
        var groups: [Int: [Int]] = [:]
        for index in sorted.indices { groups[union.find(index), default: []].append(index) }
        struct Group { let primary: WorkoutRecord; let merged: [WorkoutRecord]; let members: Set<Int> }
        var built: [Group] = []
        var groupOf: [Int: Int] = [:]
        for members in groups.values {
            let ordered = members.map { sorted[$0] }.sorted(by: rankedBefore)
            let group = Group(primary: ordered[0], merged: Array(ordered.dropFirst()), members: Set(members))
            for member in members { groupOf[member] = built.count }
            built.append(group)
        }

        // 疑似重复：组与组之间，不传递。
        var counterparts: [Int: Set<Int>] = [:]
        for (i, j) in suspectedPairs {
            guard let gi = groupOf[i], let gj = groupOf[j], gi != gj else { continue }
            counterparts[gi, default: []].insert(gj)
            counterparts[gj, default: []].insert(gi)
        }

        // 按优先级贪心决定计入：已被计入的条目的疑似对手不计入；对手已被排除的条目不受牵连。
        let ranked = built.indices.sorted { rankedBefore(built[$0].primary, built[$1].primary) }
        var counted = Set<Int>()
        for index in ranked {
            let blockedByCounted = counterparts[index, default: []].contains { counted.contains($0) }
            if !blockedByCounted { counted.insert(index) }
        }

        let entries = built.indices.map { index in
            DeduplicatedWorkout(
                primary: built[index].primary,
                mergedDuplicates: built[index].merged,
                suspectedCounterparts: counterparts[index, default: []]
                    .map { built[$0].primary.id }
                    .sorted { $0.uuidString < $1.uuidString },
                countsTowardTotals: counted.contains(index)
            )
        }.sorted { stableOrder($0.primary, $1.primary) }
        return WorkoutDeduplicationResult(entries: entries)
    }

    private static func stableOrder(_ a: WorkoutRecord, _ b: WorkoutRecord) -> Bool {
        if a.startDate != b.startDate { return a.startDate > b.startDate }
        return a.id.uuidString < b.id.uuidString
    }

    /// 主记录优先级：数据更完整 → Apple 原生来源 → 较早开始 → UUID。确定性，与输入顺序无关。
    private static func rankedBefore(_ a: WorkoutRecord, _ b: WorkoutRecord) -> Bool {
        let (ca, cb) = (completeness(a), completeness(b))
        if ca != cb { return ca > cb }
        if a.source.isAppleNative != b.source.isAppleNative { return a.source.isAppleNative }
        if a.startDate != b.startDate { return a.startDate < b.startDate }
        return a.id.uuidString < b.id.uuidString
    }

    private static func completeness(_ record: WorkoutRecord) -> Int {
        [record.distanceMeters != nil, record.averageHeartRate != nil, record.activeEnergyKilocalories != nil, record.location != .unknown]
            .filter { $0 }.count
    }
}

private struct UnionFind {
    private var parent: [Int]
    init(count: Int) { parent = Array(0..<count) }
    mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var node = x
        while parent[node] != root { (node, parent[node]) = (parent[node], root) }
        return root
    }
    mutating func merge(_ a: Int, _ b: Int) {
        let (ra, rb) = (find(a), find(b))
        if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
    }
}
