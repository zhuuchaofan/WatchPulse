import Foundation
import WatchPulseShared

/// 主观疲劳记录的存储契约。默认仅本地：不引入云端同步、账号或第三方 SDK。
///
/// - 同一运动至多一条记录，可修改、可删除；
/// - 运动记录消失后记录转为“未关联”并保留，只有用户明确清理才删除（`purgeOrphans`）；
/// - 重装 / 换机：删除 App 会删除本地数据；系统备份还原时随 App 数据迁移，WatchPulse 自身不做同步。
///   持久化实现（T5）必须遵守同一契约；此处的内存实现是参考实现与测试替身。
public protocol PerceivedEffortStore: Sendable {
    /// 保存或修改某次运动的记录。强度与感受都为空时删除已有记录并返回 `nil`。
    func save(for workout: WorkoutRecord, effort: Int?, feelings: Set<BodyFeeling>, now: Date) async throws -> PerceivedEffortRecord?
    func delete(workoutID: UUID) async throws
    func allRecords() async -> [PerceivedEffortRecord]
    /// 仅返回仍与运动关联的记录；孤儿记录不参与展示与分析。
    func linkedRecord(forWorkoutID id: UUID) async -> PerceivedEffortRecord?
    func orphanedRecords() async -> [PerceivedEffortRecord]
    func reconcile(with workouts: [WorkoutRecord], coverage: DateInterval, now: Date) async -> PerceivedEffortReconciler.Summary
    /// 用户明确要求时删除全部孤儿记录，返回删除条数。
    func purgeOrphans() async -> Int
}

public actor InMemoryPerceivedEffortStore: PerceivedEffortStore {
    private var records: [PerceivedEffortRecord]

    public init(records: [PerceivedEffortRecord] = []) {
        self.records = records
    }

    public func save(for workout: WorkoutRecord, effort: Int?, feelings: Set<BodyFeeling>, now: Date) throws -> PerceivedEffortRecord? {
        if let index = records.firstIndex(where: { $0.key.workoutID == workout.id }) {
            guard let edited = records[index].updating(effort: effort, feelings: feelings, now: now) else {
                records.remove(at: index)
                return nil
            }
            records[index] = edited
            return edited
        }
        guard let created = PerceivedEffortRecord(id: UUID(), workout: workout, effort: effort, feelings: feelings, now: now) else {
            return nil
        }
        records.append(created)
        return created
    }

    public func delete(workoutID: UUID) {
        records.removeAll { $0.key.workoutID == workoutID }
    }

    public func allRecords() -> [PerceivedEffortRecord] { records }

    public func linkedRecord(forWorkoutID id: UUID) -> PerceivedEffortRecord? {
        records.first { $0.key.workoutID == id && $0.linkState == .linked }
    }

    public func orphanedRecords() -> [PerceivedEffortRecord] {
        records.filter { if case .orphaned = $0.linkState { return true } else { return false } }
    }

    public func reconcile(with workouts: [WorkoutRecord], coverage: DateInterval, now: Date) -> PerceivedEffortReconciler.Summary {
        let result = PerceivedEffortReconciler.reconcile(records, workouts: workouts, coverage: coverage, now: now)
        records = result.records
        return result.summary
    }

    public func purgeOrphans() -> Int {
        let before = records.count
        records.removeAll { if case .orphaned = $0.linkState { return true } else { return false } }
        return before - records.count
    }
}
