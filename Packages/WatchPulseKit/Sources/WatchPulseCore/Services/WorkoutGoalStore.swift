import Foundation
import WatchPulseShared

/// 个人运动目标的本地存储。默认仅本机：不引入云端同步、账号或第三方 SDK。
///
/// 删除 App 会删除目标；启用系统备份（iCloud / 本机备份）时随 App 数据一起恢复，WatchPulse 自身不做同步。
@MainActor
public protocol WorkoutGoalStore: AnyObject {
    /// 按创建时间升序。
    func allGoals() -> [WorkoutGoal]
    /// 新增或替换（按 `id`）。
    func save(_ goal: WorkoutGoal)
    func delete(id: UUID)
    /// 上次读取时存储数据无法解析：原始数据已备份，目标列表从空开始。界面据此提示一次。
    var recoveredFromUnreadableData: Bool { get }
}

/// 内存实现：演示模式与测试使用，不写入磁盘。
@MainActor
public final class InMemoryWorkoutGoalStore: WorkoutGoalStore {
    private var goals: [WorkoutGoal]

    public init(goals: [WorkoutGoal] = []) {
        self.goals = goals
    }

    public var recoveredFromUnreadableData: Bool { false }

    public func allGoals() -> [WorkoutGoal] {
        goals.sorted(by: WorkoutGoalOrdering.before)
    }

    public func save(_ goal: WorkoutGoal) {
        goals.removeAll { $0.id == goal.id }
        goals.append(goal)
    }

    public func delete(id: UUID) {
        goals.removeAll { $0.id == id }
    }
}

/// `UserDefaults` 实现（App 本机沙盒）。
///
/// 存储数据无法解析时**不静默覆盖**：先把原始数据复制到备份键，再从空列表开始，并标记 `recoveredFromUnreadableData`。
@MainActor
public final class UserDefaultsWorkoutGoalStore: WorkoutGoalStore {
    public static let goalsKey = "WatchPulse.workoutGoals.v1"
    public static let unreadableBackupKey = "WatchPulse.workoutGoals.v1.unreadableBackup"

    private let defaults: UserDefaults
    private var goals: [WorkoutGoal]
    public private(set) var recoveredFromUnreadableData = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.goalsKey) else {
            goals = []
            return
        }
        if let decoded = try? JSONDecoder().decode([WorkoutGoal].self, from: data) {
            goals = decoded
        } else {
            defaults.set(data, forKey: Self.unreadableBackupKey)
            defaults.removeObject(forKey: Self.goalsKey)
            goals = []
            recoveredFromUnreadableData = true
        }
    }

    public func allGoals() -> [WorkoutGoal] {
        goals.sorted(by: WorkoutGoalOrdering.before)
    }

    public func save(_ goal: WorkoutGoal) {
        goals.removeAll { $0.id == goal.id }
        goals.append(goal)
        persist()
    }

    public func delete(id: UUID) {
        goals.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(goals) {
            defaults.set(data, forKey: Self.goalsKey)
        }
    }
}

enum WorkoutGoalOrdering {
    static func before(_ a: WorkoutGoal, _ b: WorkoutGoal) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id.uuidString < b.id.uuidString
    }
}
