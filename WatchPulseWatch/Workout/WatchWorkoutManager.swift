import HealthKit
import Observation
import WatchPulseShared

/// Watch 端运动主会话管理（第一阶段占位）。
///
/// 下一阶段按 Apple “Building a multidevice workout app” 实现：
/// - `requestWorkoutAuthorization()`：请求写 `HKWorkoutType.workoutType()`、读心率/能量/距离；
/// - `startWorkout(_:)`：`makeHKConfiguration(from:)` → `HKWorkoutSession(healthStore:configuration:)`
///   → `session.associatedWorkoutBuilder()` → `startMirroringToCompanionDevice()`
///   → `startActivity(with:)` → `builder.beginCollection(at:)`；
/// - 在 `HKWorkoutSessionDelegate` / `HKLiveWorkoutBuilderDelegate` 中更新 `phase`、`latestMetrics`，
///   并用 `WorkoutMirroringCodec` 编码后 `sendToRemoteWorkoutSession(data:)`。
///
/// 运动所需的 `WKBackgroundModes = workout-processing` 已在 Info.plist 中声明。
@MainActor
@Observable
final class WatchWorkoutManager: WorkoutSessionManaging {
    private(set) var phase: WorkoutSessionPhase = .notStarted
    private(set) var latestMetrics: WorkoutMetricsSnapshot?

    @ObservationIgnored
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestWorkoutAuthorization() async throws {
        throw WorkoutSessionError.notImplementedInThisPhase
    }

    func startWorkout(_ configuration: WorkoutConfigurationRequest) async throws {
        throw WorkoutSessionError.notImplementedInThisPhase
    }

    func pause() {}

    func resume() {}

    func end() async throws {
        throw WorkoutSessionError.notImplementedInThisPhase
    }

    /// 共享配置到 HealthKit 配置的映射，供下一阶段 `startWorkout(_:)` 使用。
    nonisolated static func makeHKConfiguration(from request: WorkoutConfigurationRequest) -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        switch request.activity {
        case .running:
            configuration.activityType = .running
        case .walking:
            configuration.activityType = .walking
        case .cycling:
            configuration.activityType = .cycling
        case .highIntensityIntervalTraining:
            configuration.activityType = .highIntensityIntervalTraining
        case .other:
            configuration.activityType = .other
        }
        switch request.location {
        case .indoor:
            configuration.locationType = .indoor
        case .outdoor:
            configuration.locationType = .outdoor
        case .unknown:
            configuration.locationType = .unknown
        }
        return configuration
    }

    /// `HKWorkoutSessionState` 到共享阶段的映射，供下一阶段的 delegate 使用。
    nonisolated static func phase(from state: HKWorkoutSessionState) -> WorkoutSessionPhase {
        switch state {
        case .notStarted:
            return .notStarted
        case .prepared:
            return .prepared
        case .running:
            return .running
        case .paused:
            return .paused
        case .stopped:
            return .stopped
        case .ended:
            return .ended
        @unknown default:
            return .notStarted
        }
    }
}
