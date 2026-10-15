#if canImport(HealthKit)
import Foundation
import HealthKit
import WatchPulseShared

/// 基于 HealthKit 的真实实现。只读，不写入任何健康数据。
///
/// `HKHealthStore` 是线程安全的（Apple 文档），因此标记为 `@unchecked Sendable`。
public final class HealthKitHealthDataService: HealthDataService, @unchecked Sendable {
    private let healthStore: HKHealthStore

    public init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    static var heartRateUnit: HKUnit {
        HKUnit.count().unitDivided(by: .minute())
    }

    static var readTypes: Set<HKObjectType> {
        [HKQuantityType(.heartRate)]
    }

    public var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    public func authorizationRequestStatus() async throws -> HealthAuthorizationRequestStatus {
        guard isHealthDataAvailable else { throw HealthDataError.healthDataUnavailable }
        do {
            let status = try await healthStore.statusForAuthorizationRequest(toShare: [], read: Self.readTypes)
            switch status {
            case .shouldRequest:
                return .shouldRequest
            case .unnecessary:
                return .unnecessary
            case .unknown:
                return .unknown
            @unknown default:
                return .unknown
            }
        } catch {
            throw Self.mapError(error, whileAuthorizing: true)
        }
    }

    public func requestAuthorization() async throws {
        guard isHealthDataAvailable else { throw HealthDataError.healthDataUnavailable }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: Self.readTypes)
        } catch {
            throw Self.mapError(error, whileAuthorizing: true)
        }
    }

    public func fetchLatestHeartRate() async throws -> HeartRateSample? {
        guard isHealthDataAvailable else { throw HealthDataError.healthDataUnavailable }

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.heartRate))],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )

        let samples: [HKQuantitySample]
        do {
            samples = try await descriptor.result(for: healthStore)
        } catch {
            throw Self.mapError(error, whileAuthorizing: false)
        }

        // 空结果可能是“确实没有记录”，也可能是“读取权限被拒绝”，HealthKit 不区分二者。
        return samples.first.map(Self.makeHeartRateSample)
    }

    static func makeHeartRateSample(from sample: HKQuantitySample) -> HeartRateSample {
        let sourceRevision = sample.sourceRevision
        return HeartRateSample(
            id: sample.uuid,
            beatsPerMinute: sample.quantity.doubleValue(for: heartRateUnit),
            unit: heartRateUnit.unitString,
            startDate: sample.startDate,
            endDate: sample.endDate,
            source: HealthSampleSource(
                name: sourceRevision.source.name,
                bundleIdentifier: sourceRevision.source.bundleIdentifier,
                productType: sourceRevision.productType,
                deviceName: sample.device?.name,
                deviceModel: sample.device?.model
            )
        )
    }

    static func mapError(_ error: Error, whileAuthorizing: Bool) -> HealthDataError {
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
