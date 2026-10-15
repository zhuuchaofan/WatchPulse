import Foundation

/// 运动后的身体感受标签（用户自述，仅本地保存，不合成分数，不做医学判断）。
public enum BodyFeeling: String, CaseIterable, Hashable, Codable, Sendable {
    case energetic
    case normal
    case tired
    case sore
    case unwell

    public var title: String {
        switch self {
        case .energetic: return "精力充沛"
        case .normal: return "状态一般"
        case .tired: return "有些疲劳"
        case .sore: return "肌肉酸痛"
        case .unwell: return "身体不适"
        }
    }
}

/// 把主观记录关联到运动的稳定键：HealthKit UUID 为主键，指纹用于 UUID 变化（备份还原等）后重新关联。
public struct WorkoutKey: Hashable, Codable, Sendable {
    public var workoutID: UUID
    public let startDate: Date
    public let activity: WorkoutActivityKind
    public let duration: TimeInterval
    public let sourceKey: String

    public init(workout: WorkoutRecord) {
        workoutID = workout.id
        startDate = workout.startDate
        activity = workout.activity
        duration = workout.duration
        sourceKey = workout.source.sourceKey
    }

    /// 指纹匹配：活动类型与来源相同，开始时刻与时长各相差不超过 `tolerance` 秒。
    public func fingerprintMatches(_ workout: WorkoutRecord, tolerance: TimeInterval = 2) -> Bool {
        activity == workout.activity
            && sourceKey == workout.source.sourceKey
            && abs(startDate.timeIntervalSince(workout.startDate)) <= tolerance
            && abs(duration - workout.duration) <= tolerance
    }
}

/// 一次运动的主观记录。默认仅保存在本机，与运动一一对应，可修改、可删除。
public struct PerceivedEffortRecord: Identifiable, Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1
    public static let effortRange = 1...10

    public enum LinkState: Hashable, Codable, Sendable {
        case linked
        /// 对应的运动已不在「健康」中；记录保留，不参与展示与分析，由用户决定是否清理。
        case orphaned(since: Date)
    }

    public let id: UUID
    public var key: WorkoutKey
    /// 自觉用力程度 1–10，可空。
    public private(set) var effort: Int?
    public private(set) var feelings: Set<BodyFeeling>
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public var linkState: LinkState
    public let schemaVersion: Int

    /// 强度与感受都为空、或强度越界时返回 `nil`（空记录应当删除而不是保存）。
    public init?(id: UUID, workout: WorkoutRecord, effort: Int?, feelings: Set<BodyFeeling>, now: Date) {
        guard Self.isValid(effort: effort, feelings: feelings) else { return nil }
        self.id = id
        key = WorkoutKey(workout: workout)
        self.effort = effort
        self.feelings = feelings
        createdAt = now
        updatedAt = now
        linkState = .linked
        schemaVersion = Self.currentSchemaVersion
    }

    private static func isValid(effort: Int?, feelings: Set<BodyFeeling>) -> Bool {
        if let effort, !effortRange.contains(effort) { return false }
        return effort != nil || !feelings.isEmpty
    }

    /// 修改内容，保留 `id` 与创建时间；结果为空或越界时返回 `nil`。
    public func updating(effort: Int?, feelings: Set<BodyFeeling>, now: Date) -> PerceivedEffortRecord? {
        guard Self.isValid(effort: effort, feelings: feelings) else { return nil }
        var copy = self
        copy.effort = effort
        copy.feelings = feelings
        copy.updatedAt = now
        return copy
    }
}

/// 把主观记录与「健康」中当前的运动重新对账。**只改变关联状态，从不删除记录。**
public enum PerceivedEffortReconciler {
    public struct Summary: Hashable, Sendable {
        public var relinked = 0
        public var newlyOrphaned = 0
        public var restored = 0
        public init() {}
    }

    public struct Result: Sendable {
        public let records: [PerceivedEffortRecord]
        public let summary: Summary
    }

    /// - Parameters:
    ///   - workouts: 本次从 HealthKit 读取到的运动。
    ///   - coverage: 本次读取覆盖的时间范围；范围之外的记录无法判断是否消失，保持不变。
    public static func reconcile(
        _ records: [PerceivedEffortRecord],
        workouts: [WorkoutRecord],
        coverage: DateInterval,
        now: Date
    ) -> Result {
        // 空列表无法区分“没有运动”与“未授权读取”，不据此改变任何关联。
        guard !workouts.isEmpty else { return Result(records: records, summary: Summary()) }

        let present = Set(workouts.map(\.id))
        var summary = Summary()

        // 第一遍：UUID 仍存在的记录；找出需要尝试指纹重新关联的记录及其唯一候选。
        var candidateOf: [UUID: UUID] = [:] // 记录 id → 唯一候选运动 id
        for record in records where !present.contains(record.key.workoutID) && coverage.contains(record.key.startDate) {
            // 候选：指纹匹配、且尚未被其他记录占用的运动。
            let matches = workouts.filter { candidate in
                record.key.fingerprintMatches(candidate) && !records.contains { $0.key.workoutID == candidate.id }
            }
            if matches.count == 1 { candidateOf[record.id] = matches[0].id }
        }
        // 同一个运动被多条记录同时指向时不重新关联。
        var claims: [UUID: Int] = [:]
        for workoutID in candidateOf.values { claims[workoutID, default: 0] += 1 }

        let updated = records.map { record -> PerceivedEffortRecord in
            var record = record
            if present.contains(record.key.workoutID) {
                if case .orphaned = record.linkState {
                    record.linkState = .linked
                    summary.restored += 1
                }
            } else if !coverage.contains(record.key.startDate) {
                // 超出本次读取范围：保持不变。
            } else if let target = candidateOf[record.id], claims[target] == 1 {
                record.key.workoutID = target
                record.linkState = .linked
                summary.relinked += 1
            } else if case .linked = record.linkState {
                record.linkState = .orphaned(since: now)
                summary.newlyOrphaned += 1
            }
            return record
        }
        return Result(records: updated, summary: summary)
    }
}
