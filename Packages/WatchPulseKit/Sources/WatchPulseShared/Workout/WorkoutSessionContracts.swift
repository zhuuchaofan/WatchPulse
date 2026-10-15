import Foundation

/// 运动会话相关错误。
public enum WorkoutSessionError: Error, Hashable, Sendable {
    case healthDataUnavailable
    case authorizationFailed(reason: String)
    case sessionStartFailed(reason: String)
    case sessionFailed(reason: String)
    case noActiveSession
    /// 当前阶段不允许执行该操作（例如未开始时暂停）。
    case invalidTransition(from: WorkoutSessionPhase, action: String)
    /// 与对端设备未连接。
    case notConnected
    /// 多次重连失败，运动在 Watch 上继续本地记录。
    case mirroringUnavailable
    case saveFailed(reason: String)
}

extension WorkoutSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "此设备不支持健康数据。"
        case .authorizationFailed(let reason):
            return "运动授权失败：\(reason)"
        case .sessionStartFailed(let reason):
            return "无法开始运动：\(reason)"
        case .sessionFailed(let reason):
            return "运动会话出错：\(reason)"
        case .noActiveSession:
            return "当前没有进行中的运动。"
        case .invalidTransition(let phase, let action):
            return "运动\(phase.title)时无法\(action)。"
        case .notConnected:
            return "未连接到对端设备。"
        case .mirroringUnavailable:
            return "暂时无法连接 iPhone，运动仍在 Apple Watch 上记录。"
        case .saveFailed(let reason):
            return "保存运动失败：\(reason)"
        }
    }
}

/// 运动驱动层上报的事件。
public enum WorkoutDriverEvent: Sendable {
    case phaseChanged(WorkoutSessionPhase, at: Date)
    case metrics(WorkoutMetricsSnapshot)
    /// 收到对端（iPhone）发来的数据。
    case remoteDataReceived(Data)
    /// 镜像已确认建立（例如 `startMirroringToCompanionDevice` 成功）。仅有发送器对象不代表已连接。
    case mirroringConnected
    /// 镜像连接断开。
    case mirroringDisconnected(reason: String?)
    case failed(reason: String)
}

/// Watch 端运动会话的驱动层。真实实现封装 `HKWorkoutSession` + `HKLiveWorkoutBuilder`，
/// 模拟实现 `SimulatedWorkoutSessionDriver` 用于测试、Preview 与演示模式。
///
/// 驱动只负责“执行”，状态机与镜像同步逻辑在 `WorkoutSessionController` 中，便于测试。
@MainActor
public protocol WorkoutSessionDriver: AnyObject {
    /// 事件回调，在主线程调用。
    var eventHandler: ((WorkoutDriverEvent) -> Void)? { get set }
    var dataOrigin: HealthDataOrigin { get }

    func requestAuthorization() async throws
    /// 创建会话、开始镜像到 iPhone、开始采集。镜像建立后上报 `.mirroringConnected`；
    /// 镜像失败不应阻止运动开始，而应上报 `.mirroringDisconnected`。
    func start(_ configuration: WorkoutConfigurationRequest, at date: Date) async throws
    func pause(at date: Date)
    func resume(at date: Date)
    /// 停止运动并保存：`stopActivity` → 等待 `.stopped` → `endCollection` → `finishWorkout`。
    /// 会话保持存在（镜像仍可发送保存结果），之后由 `endSession()` 结束。
    /// - Returns: HealthKit 返回的已保存运动；未返回记录时应抛出错误。
    func stopAndSave(at date: Date) async throws -> WorkoutRecord
    /// 结束会话并释放资源（`session.end()`），镜像连接随之关闭。无论保存成败都必须调用。
    func endSession()
    /// 镜像断开后重新连接 iPhone。
    func reconnectMirroring() async throws
    /// App 崩溃或被系统终止后恢复进行中的运动；没有可恢复的运动返回 `nil`。
    func recoverActiveSession() async throws -> WorkoutStateSnapshot?
}

/// 向对端设备发送镜像数据。
///
/// 发送是“尽力而为”的同步调用：未连接时立即抛出 `WorkoutSessionError.notConnected`；
/// 已交给系统但最终失败的情况由真实实现通过断线事件上报。这样状态机可以完全同步、可测试。
@MainActor
public protocol WorkoutMirroringSender: AnyObject {
    func send(_ data: Data) throws
}
