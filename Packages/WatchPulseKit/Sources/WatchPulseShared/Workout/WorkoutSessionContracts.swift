/// 运动会话相关错误。
public enum WorkoutSessionError: Error, Hashable, Sendable {
    /// 第一阶段尚未实现实时运动会话与镜像。
    case notImplementedInThisPhase
    /// 当前没有进行中的会话。
    case noActiveSession
}

/// Watch 端：运动主会话的所有者。
///
/// 后续实现（参考 Apple “Building a multidevice workout app”）：
/// 1. 用 `WorkoutConfigurationRequest` 构造 `HKWorkoutConfiguration`，创建
///    `HKWorkoutSession` 与 `HKLiveWorkoutBuilder`；
/// 2. 调用 `session.startMirroringToCompanionDevice()` 把会话镜像到 iPhone；
/// 3. `session.startActivity(with:)` + `builder.beginCollection(at:)`；
/// 4. 在 `HKLiveWorkoutBuilderDelegate` 中汇总 `WorkoutMetricsSnapshot`，
///    用 `WorkoutMirroringCodec` 编码后 `sendToRemoteWorkoutSession(data:)`；
/// 5. 在 `HKWorkoutSessionDelegate` 中把状态变化映射为 `WorkoutSessionPhase` 并通知 iPhone，
///    同时处理 iPhone 发来的 `WorkoutRemoteCommand`。
@MainActor
public protocol WorkoutSessionManaging: AnyObject {
    var phase: WorkoutSessionPhase { get }
    var latestMetrics: WorkoutMetricsSnapshot? { get }

    func requestWorkoutAuthorization() async throws
    func startWorkout(_ configuration: WorkoutConfigurationRequest) async throws
    func pause()
    func resume()
    func end() async throws
}

/// iPhone 端：镜像会话的接收方。
///
/// 后续实现：
/// 1. App 启动早期（`application(_:didFinishLaunchingWithOptions:)` 阶段）设置
///    `healthStore.workoutSessionMirroringStartHandler`，系统可能在后台拉起 App 来投递镜像会话；
/// 2. 收到 `HKWorkoutSession` 后设置 delegate，解码 Watch 发来的 `WorkoutMirroringMessage`；
/// 3. 用 `send(_:)` 把 `WorkoutRemoteCommand` 编码后发回 Watch。
@MainActor
public protocol MirroredWorkoutReceiving: AnyObject {
    var phase: WorkoutSessionPhase { get }
    var latestMetrics: WorkoutMetricsSnapshot? { get }

    func startObservingMirroredSessions()
    func send(_ command: WorkoutRemoteCommand) async throws
}
