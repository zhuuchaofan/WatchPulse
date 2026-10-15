import Foundation

/// 运动类型。后续由 Watch 端映射为 `HKWorkoutActivityType`。
public enum WorkoutActivityKind: String, CaseIterable, Codable, Sendable {
    case running
    case walking
    case cycling
    case highIntensityIntervalTraining
    case other
}

/// 运动场地。后续映射为 `HKWorkoutSessionLocationType`。
public enum WorkoutLocation: String, CaseIterable, Codable, Sendable {
    case indoor
    case outdoor
    case unknown
}

/// 发起一次运动所需的配置。后续在 Watch 端转换为 `HKWorkoutConfiguration`。
public struct WorkoutConfigurationRequest: Hashable, Codable, Sendable {
    public let activity: WorkoutActivityKind
    public let location: WorkoutLocation

    public init(activity: WorkoutActivityKind, location: WorkoutLocation) {
        self.activity = activity
        self.location = location
    }
}
