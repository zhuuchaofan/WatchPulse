#if canImport(HealthKit)
import Foundation
import HealthKit
import WatchPulseShared

/// 共享模型与 HealthKit 运动类型之间的转换。
public enum HealthKitWorkoutMapping {
    public static func activityType(for activity: WorkoutActivityKind) -> HKWorkoutActivityType {
        switch activity {
        case .running: return .running
        case .walking: return .walking
        case .cycling: return .cycling
        case .highIntensityIntervalTraining: return .highIntensityIntervalTraining
        case .other: return .other
        }
    }

    public static func activity(for type: HKWorkoutActivityType) -> WorkoutActivityKind {
        switch type {
        case .running: return .running
        case .walking: return .walking
        case .cycling: return .cycling
        case .highIntensityIntervalTraining: return .highIntensityIntervalTraining
        default: return .other
        }
    }

    #if os(iOS) || os(watchOS)
    public static func configuration(from request: WorkoutConfigurationRequest) -> HKWorkoutConfiguration {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activityType(for: request.activity)
        switch request.location {
        case .indoor: configuration.locationType = .indoor
        case .outdoor: configuration.locationType = .outdoor
        case .unknown: configuration.locationType = .unknown
        }
        return configuration
    }

    public static func request(from configuration: HKWorkoutConfiguration) -> WorkoutConfigurationRequest {
        let location: WorkoutLocation
        switch configuration.locationType {
        case .indoor: location = .indoor
        case .outdoor: location = .outdoor
        default: location = .unknown
        }
        return WorkoutConfigurationRequest(activity: activity(for: configuration.activityType), location: location)
    }

    public static func phase(from state: HKWorkoutSessionState) -> WorkoutSessionPhase {
        switch state {
        case .notStarted: return .notStarted
        case .prepared: return .prepared
        case .running: return .running
        case .paused: return .paused
        case .stopped: return .stopped
        case .ended: return .ended
        @unknown default: return .notStarted
        }
    }
    #endif

    /// 来源、设备与外部标识（用于去重与可比较性判断）。缺失的字段保持 `nil`。
    static func sourceInfo(from workout: HKWorkout) -> WorkoutSourceInfo {
        let source = workout.sourceRevision.source
        let device = workout.device
        let metadata = workout.metadata
        return WorkoutSourceInfo(
            name: source.name,
            bundleIdentifier: source.bundleIdentifier,
            deviceName: device?.name,
            deviceModel: device?.model,
            deviceHardwareVersion: device?.hardwareVersion,
            externalIdentifier: metadata?[HKMetadataKeyExternalUUID] as? String,
            syncIdentifier: metadata?[HKMetadataKeySyncIdentifier] as? String
        )
    }

    /// `HKWorkout` → 运动记录（含心率、能量、距离统计）。
    public static func record(from workout: HKWorkout) -> WorkoutRecord {
        let bpm = HealthKitTypes.beatsPerMinute
        let heartRate = workout.statistics(for: HKQuantityType(.heartRate))
        let energy = workout.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()
        let distance = (workout.statistics(for: HKQuantityType(.distanceWalkingRunning))
            ?? workout.statistics(for: HKQuantityType(.distanceCycling)))?.sumQuantity()

        let location: WorkoutLocation
        if let indoor = workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool {
            location = indoor ? .indoor : .outdoor
        } else {
            location = .unknown
        }

        return WorkoutRecord(
            id: workout.uuid,
            activity: activity(for: workout.workoutActivityType),
            location: location,
            startDate: workout.startDate,
            endDate: workout.endDate,
            duration: workout.duration,
            activeEnergyKilocalories: energy?.doubleValue(for: .kilocalorie()),
            distanceMeters: distance?.doubleValue(for: .meter()),
            averageHeartRate: heartRate?.averageQuantity()?.doubleValue(for: bpm),
            maximumHeartRate: heartRate?.maximumQuantity()?.doubleValue(for: bpm),
            minimumHeartRate: heartRate?.minimumQuantity()?.doubleValue(for: bpm),
            sourceName: workout.sourceRevision.source.name,
            sourceInfo: sourceInfo(from: workout)
        )
    }
}
#endif

/// 把非 `Sendable` 的系统对象（例如 `HKWorkoutSession`）从系统回调线程传到主线程。
/// 仅在确认对象只会在主线程使用时使用。
public struct UncheckedSendableBox<Value>: @unchecked Sendable {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }
}
