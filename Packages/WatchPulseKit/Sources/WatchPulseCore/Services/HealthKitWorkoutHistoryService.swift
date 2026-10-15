#if canImport(HealthKit)
import Foundation
import HealthKit
import WatchPulseShared

/// 从 HealthKit 读取运动记录与运动期间的心率。
public final class HealthKitWorkoutHistoryService: WorkoutHistoryService, @unchecked Sendable {
    private let healthStore: HKHealthStore

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    public var dataOrigin: HealthDataOrigin { .healthKit }

    public var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    public func fetchWorkouts(limit: Int) async throws -> [WorkoutRecord] {
        guard isHealthDataAvailable else { throw HealthDataError.healthDataUnavailable }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout()],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: limit
        )
        do {
            return try await descriptor.result(for: healthStore).map(HealthKitWorkoutMapping.record(from:))
        } catch {
            throw HealthKitErrorMapping.map(error, whileAuthorizing: false)
        }
    }

    public func fetchHeartRateSeries(from start: Date, to end: Date) async throws -> [HeartRatePoint] {
        guard isHealthDataAvailable else { throw HealthDataError.healthDataUnavailable }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(
                type: HKQuantityType(.heartRate),
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            )],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let unit = HealthKitTypes.beatsPerMinute
        do {
            return try await descriptor.result(for: healthStore).map {
                HeartRatePoint(date: $0.startDate, beatsPerMinute: $0.quantity.doubleValue(for: unit))
            }
        } catch {
            throw HealthKitErrorMapping.map(error, whileAuthorizing: false)
        }
    }
}
#endif
