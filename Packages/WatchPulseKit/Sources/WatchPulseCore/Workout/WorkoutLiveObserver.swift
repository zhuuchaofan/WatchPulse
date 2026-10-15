import Foundation
import WatchPulseShared

/// 挂在 Watch 端运动状态机上的扩展点（v0.2：GPS 测速、心率区间提醒）。
///
/// 观察者**不能**创建或控制运动会话，也不能改变开始 / 暂停 / 结束 / 保存流程；
/// 它只能在指标发布前补充字段（例如速度），并在运动开始、阶段变化、结束时得到通知。
@MainActor
public protocol WorkoutLiveObserver: AnyObject {
    /// 运动开始（或崩溃恢复后继续）。
    func workoutDidStart(_ configuration: WorkoutConfigurationRequest, at date: Date)
    /// 阶段变化（运行 / 暂停 / 停止 …）。
    func workoutPhaseDidChange(to phase: WorkoutSessionPhase, at date: Date)
    /// 每条指标在保存到状态机并发给 iPhone 之前调用，可补充字段。
    /// 不得修改 `timestamp` 与 `elapsedTime`（计时由 HealthKit 决定）。
    func workoutMetricsWillPublish(_ metrics: WorkoutMetricsSnapshot) -> WorkoutMetricsSnapshot
    /// 用户开始结束运动（停止 GPS 等资源），之后不会再有指标。
    func workoutDidEnd()
}

extension WorkoutLiveObserver {
    public func workoutDidStart(_ configuration: WorkoutConfigurationRequest, at date: Date) {}
    public func workoutPhaseDidChange(to phase: WorkoutSessionPhase, at date: Date) {}
    public func workoutMetricsWillPublish(_ metrics: WorkoutMetricsSnapshot) -> WorkoutMetricsSnapshot { metrics }
    public func workoutDidEnd() {}
}

/// 一条定位样本（与 Core Location 解耦，便于在 Linux 上测试）。
///
/// 取值语义与 `CLLocation` 一致：`speed` 单位米 / 秒，负数表示无效；`speedAccuracy`、`horizontalAccuracy`
/// 负数表示无效 / 未知。
public struct LocationFix: Hashable, Sendable {
    public let timestamp: Date
    public let speed: Double
    public let speedAccuracy: Double
    public let horizontalAccuracy: Double

    public init(timestamp: Date, speed: Double, speedAccuracy: Double, horizontalAccuracy: Double) {
        self.timestamp = timestamp
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.horizontalAccuracy = horizontalAccuracy
    }
}

/// 定位授权状态。
public enum LocationAuthorization: Hashable, Sendable {
    case notDetermined
    case authorized
    /// 用户拒绝或受限制。
    case denied
}

/// 定位数据提供者。真实实现封装 `CLLocationManager`（Watch App 中），模拟实现用于测试与演示。
@MainActor
public protocol LocationFixProvider: AnyObject {
    var dataOrigin: HealthDataOrigin { get }
    var authorization: LocationAuthorization { get }
    /// 新定位样本，在主线程回调。
    var fixHandler: ((LocationFix) -> Void)? { get set }
    /// 授权状态变化，在主线程回调。
    var authorizationHandler: ((LocationAuthorization) -> Void)? { get set }
    /// 请求“使用 App 期间”定位授权（会弹出系统授权框）。
    func requestAuthorization()
    func startUpdates()
    func stopUpdates()
}

/// 心率区间提醒的震动类型。
public enum ZoneHapticKind: Hashable, Sendable {
    /// 高于目标区间。
    case aboveZone
    /// 低于目标区间。
    case belowZone
}

/// 播放震动。真实实现为 `WKInterfaceDevice.current().play(_:)`，测试中记录调用。
@MainActor
public protocol HapticPlaying: AnyObject {
    func play(_ kind: ZoneHapticKind)
}
