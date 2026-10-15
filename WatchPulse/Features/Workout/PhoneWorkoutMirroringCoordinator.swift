import HealthKit
import Observation
import WatchPulseShared

/// iPhone 端运动镜像接收方（第一阶段占位，未接入 App 生命周期）。
///
/// 下一阶段的接入步骤：
/// 1. 在 `WatchPulseApp` 中通过 `@UIApplicationDelegateAdaptor` 于启动早期调用
///    `startObservingMirroredSessions()`——系统可能在后台拉起 App 来投递镜像会话；
/// 2. 在 handler 中保存 `HKWorkoutSession`、设置 `HKWorkoutSessionDelegate`；
/// 3. delegate 收到 `didReceiveDataFromRemoteWorkoutSession` 后用 `WorkoutMirroringCodec.decode`
///    更新 `phase` / `latestMetrics`；
/// 4. `send(_:)` 用 `WorkoutMirroringCodec.encode(.command(...))` 后调用
///    `session.sendToRemoteWorkoutSession(data:)`。
@MainActor
@Observable
final class PhoneWorkoutMirroringCoordinator: MirroredWorkoutReceiving {
    private(set) var phase: WorkoutSessionPhase = .notStarted
    private(set) var latestMetrics: WorkoutMetricsSnapshot?

    @ObservationIgnored
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    func startObservingMirroredSessions() {
        // 第一阶段不注册 `healthStore.workoutSessionMirroringStartHandler`。
    }

    func send(_ command: WorkoutRemoteCommand) async throws {
        throw WorkoutSessionError.notImplementedInThisPhase
    }
}
