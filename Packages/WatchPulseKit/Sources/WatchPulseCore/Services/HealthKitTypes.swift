#if canImport(HealthKit)
import Foundation
import HealthKit
import WatchPulseShared

/// HealthKit 类型、单位与授权范围的唯一定义处。
public enum HealthKitTypes {
    public static var beatsPerMinute: HKUnit {
        HKUnit.count().unitDivided(by: .minute())
    }

    /// App 需要读取的全部类型（日常监控 + 运动记录）。
    public static var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [
            HKCategoryType(.sleepAnalysis),
            HKObjectType.workoutType(),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
        ]
        for kind in HealthMetricKind.allCases {
            if let type = kind.quantityType {
                types.insert(type)
            }
        }
        return types
    }

    /// 运动需要写入的类型（Apple Watch 的 `HKLiveWorkoutBuilder` 保存运动及其样本）。
    public static var workoutShareTypes: Set<HKSampleType> {
        [
            HKObjectType.workoutType(),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.distanceCycling),
        ]
    }
}

extension HealthMetricKind {
    var quantityType: HKQuantityType? {
        switch self {
        case .heartRate: return HKQuantityType(.heartRate)
        case .heartRateVariability: return HKQuantityType(.heartRateVariabilitySDNN)
        case .restingHeartRate: return HKQuantityType(.restingHeartRate)
        case .stepCount: return HKQuantityType(.stepCount)
        case .activeEnergy: return HKQuantityType(.activeEnergyBurned)
        case .sleep: return nil
        }
    }

    var healthKitUnit: HKUnit {
        switch self {
        case .heartRate, .restingHeartRate: return HealthKitTypes.beatsPerMinute
        case .heartRateVariability: return HKUnit.secondUnit(with: .milli)
        case .stepCount: return HKUnit.count()
        case .activeEnergy: return HKUnit.kilocalorie()
        case .sleep: return HKUnit.hour()
        }
    }
}

extension SleepStage {
    init?(healthKitValue: Int) {
        guard let value = HKCategoryValueSleepAnalysis(rawValue: healthKitValue) else { return nil }
        switch value {
        case .inBed: self = .inBed
        case .awake: self = .awake
        case .asleepUnspecified: self = .asleepUnspecified
        case .asleepCore: self = .core
        case .asleepDeep: self = .deep
        case .asleepREM: self = .rem
        @unknown default: return nil
        }
    }
}

enum HealthKitErrorMapping {
    static func map(_ error: Error, whileAuthorizing: Bool) -> HealthDataError {
        if let error = error as? HealthDataError {
            return error
        }
        if let hkError = error as? HKError {
            switch hkError.code {
            case .errorHealthDataUnavailable, .errorHealthDataRestricted:
                return .healthDataUnavailable
            case .errorDatabaseInaccessible:
                return .protectedDataUnavailable
            default:
                break
            }
        }
        let reason = error.localizedDescription
        return whileAuthorizing ? .authorizationFailed(reason: reason) : .queryFailed(reason: reason)
    }
}
#endif
