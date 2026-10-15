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

    public func fetchHeartRateSeries(for record: WorkoutRecord) async throws -> WorkoutHeartRateSeries {
        guard isHealthDataAvailable else { throw HealthDataError.healthDataUnavailable }
        guard let workout = try await fetchWorkout(id: record.id) else {
            return WorkoutHeartRateSeries(points: [], attribution: .workoutAssociated)
        }

        // 1. 与该运动关联的样本（HKLiveWorkoutBuilder 采集的心率会关联到运动）。
        let associated = try await heartRates(matching: HKQuery.predicateForObjects(from: workout))
        if !associated.isEmpty {
            return WorkoutHeartRateSeries(points: associated, attribution: .workoutAssociated)
        }

        let timeRange = HKQuery.predicateForSamples(withStart: workout.startDate, end: workout.endDate, options: .strictStartDate)

        // 2. 运动未关联样本（例如部分第三方 App）：只取与运动同一设备的样本。
        if let device = workout.device {
            let sameDevice = try await heartRates(matching: NSCompoundPredicate(andPredicateWithSubpredicates: [
                timeRange,
                HKQuery.predicateForObjects(from: [device]),
            ]))
            if !sameDevice.isEmpty {
                return WorkoutHeartRateSeries(points: sameDevice, attribution: .sameDevice)
            }
        }

        // 3. 无法确定设备：按时间段读取所有来源，并标注可能混入其他设备。
        return WorkoutHeartRateSeries(points: try await heartRates(matching: timeRange), attribution: .timeRangeAllSources)
    }

    private func fetchWorkout(id: UUID) async throws -> HKWorkout? {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForObject(with: id))],
            sortDescriptors: [],
            limit: 1
        )
        do {
            return try await descriptor.result(for: healthStore).first
        } catch {
            throw HealthKitErrorMapping.map(error, whileAuthorizing: false)
        }
    }

    private func heartRates(matching predicate: NSPredicate) async throws -> [HeartRatePoint] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.heartRate), predicate: predicate)],
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
