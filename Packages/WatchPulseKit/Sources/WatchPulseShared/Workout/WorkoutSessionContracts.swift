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
    /// 给普通用户看的说明：发生了什么、下一步能做什么。**不包含**系统原始错误信息。
    public var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "这台设备无法使用“健康”数据，不能记录运动。"
        case .authorizationFailed:
            return "没能获得记录运动所需的权限。请在 iPhone「设置 › 隐私与安全性 › 健康 › WatchPulse」中检查后再试。"
        case .sessionStartFailed:
            return "运动没有开始，请再试一次。如果一直失败，请重启 Apple Watch。"
        case .sessionFailed:
            return "运动记录中断了。已记录的部分可能没有保存，请在「健康」App 中查看。"
        case .noActiveSession:
            return "当前没有进行中的运动。"
        case .invalidTransition(let phase, let action):
            return "运动\(phase.title)时无法\(action)。"
        case .notConnected:
            return "Apple Watch 与 iPhone 没有连接。"
        case .mirroringUnavailable:
            return "暂时无法连接 iPhone，运动仍在 Apple Watch 上记录。"
        case .saveFailed:
            return "运动已结束，但没能保存到“健康”。请在「健康」App 中查看这次运动是否存在。"
        }
    }

    /// 开发调试用的诊断信息（含系统原始错误）。不要显示给用户。
    public var diagnosticDescription: String {
        switch self {
        case .authorizationFailed(let reason): return "authorizationFailed: \(reason)"
        case .sessionStartFailed(let reason): return "sessionStartFailed: \(reason)"
        case .sessionFailed(let reason): return "sessionFailed: \(reason)"
        case .saveFailed(let reason): return "saveFailed: \(reason)"
        case .invalidTransition(let phase, let action): return "invalidTransition: \(phase.rawValue) → \(action)"
        default: return String(describing: self)
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
/// - `send(_:)`：“尽力而为”的同步调用，用于高频的指标 / 心跳。未连接时立即抛出
///   `WorkoutSessionError.notConnected`；已交给系统但最终失败的情况由真实实现通过断线事件上报。
/// - `sendAndConfirm(_:)`：等待系统的发送完成回调（`sendToRemoteWorkoutSession(data:)` 的结果），
///   用于关闭会话前的最后一条消息，确认送达后才能安全结束会话。
@MainActor
public protocol WorkoutMirroringSender: AnyObject {
    func send(_ data: Data) throws
    func sendAndConfirm(_ data: Data) async throws
}

/// 结束运动时，等待会话进入 `.stopped` 之后如何确定结束时间。
public enum WorkoutStopResolution {
    /// - Parameters:
    ///   - observed: 委托回调报告 `.stopped` 的时间；等待超时为 `nil`。
    ///   - stateAfterWait: 等待结束后会话的实际状态。
    ///   - requested: 用户请求结束的时间。
    /// - Returns: 用于 `endCollection` 的结束时间。
    /// - Throws: 超时且会话仍未停止时抛出 `.saveFailed`，不能当作已正常停止继续保存。
    public static func stopDate(
        observed: Date?,
        stateAfterWait: WorkoutSessionPhase,
        requested: Date
    ) throws -> Date {
        if let observed {
            return observed
        }
        switch stateAfterWait {
        case .stopped, .ended:
            // 回调缺失但会话确实已停止：以请求时间结束。
            return requested
        case .notStarted, .prepared, .running, .paused:
            throw WorkoutSessionError.saveFailed(reason: "运动会话在 10 秒内未能停止（当前：\(stateAfterWait.title)），未保存")
        }
    }
}
