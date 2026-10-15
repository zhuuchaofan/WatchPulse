/// 运动会话阶段，与 `HKWorkoutSessionState` 一一对应，便于在 iPhone / Watch 之间传递。
public enum WorkoutSessionPhase: String, Codable, Sendable {
    case notStarted
    case prepared
    case running
    case paused
    case stopped
    case ended

    /// 会话是否仍处于活动中（可接收指标、可被暂停/结束）。
    public var isActive: Bool {
        switch self {
        case .prepared, .running, .paused, .stopped:
            return true
        case .notStarted, .ended:
            return false
        }
    }
}
