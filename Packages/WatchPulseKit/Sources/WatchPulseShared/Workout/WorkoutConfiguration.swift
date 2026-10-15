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

extension WorkoutActivityKind {
    public var title: String {
        switch self {
        case .running: return "跑步"
        case .walking: return "步行"
        case .cycling: return "骑行"
        case .highIntensityIntervalTraining: return "高强度间歇训练"
        case .other: return "其他运动"
        }
    }

    public var systemImage: String {
        switch self {
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .cycling: return "figure.outdoor.cycle"
        case .highIntensityIntervalTraining: return "figure.highintensity.intervaltraining"
        case .other: return "figure.mixed.cardio"
        }
    }

    /// 是否记录距离。
    public var tracksDistance: Bool {
        switch self {
        case .running, .walking, .cycling: return true
        case .highIntensityIntervalTraining, .other: return false
        }
    }
}

extension WorkoutLocation {
    public var title: String {
        switch self {
        case .indoor: return "室内"
        case .outdoor: return "室外"
        case .unknown: return "未知"
        }
    }
}
