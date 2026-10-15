#if canImport(HealthKit)
import Foundation
import HealthKit
import WatchPulseShared

/// 基于 HealthKit 的真实实现。只读取数据；写入权限仅用于 Apple Watch 保存运动。
///
/// `HKHealthStore` 是线程安全的（Apple 文档），因此标记为 `@unchecked Sendable`。
public final class HealthKitHealthDataService: HealthDataService, @unchecked Sendable {
    private let healthStore: HKHealthStore
    private let calendar: Calendar

    public init(healthStore: HKHealthStore = HKHealthStore(), calendar: Calendar = .current) {
        self.healthStore = healthStore
        self.calendar = calendar
    }

    public var dataOrigin: HealthDataOrigin { .healthKit }

    public var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    // MARK: - 授权

    public func authorizationRequestStatus() async throws -> HealthAuthorizationRequestStatus {
        guard isHealthDataAvailable else { throw HealthDataError.healthDataUnavailable }
        do {
            let status = try await healthStore.statusForAuthorizationRequest(
                toShare: HealthKitTypes.workoutShareTypes,
                read: HealthKitTypes.readTypes
            )
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
            throw HealthKitErrorMapping.map(error, whileAuthorizing: true)
        }
    }

    public func requestAuthorization() async throws {
        guard isHealthDataAvailable else { throw HealthDataError.healthDataUnavailable }
        do {
            try await healthStore.requestAuthorization(
                toShare: HealthKitTypes.workoutShareTypes,
                read: HealthKitTypes.readTypes
            )
        } catch {
            throw HealthKitErrorMapping.map(error, whileAuthorizing: true)
        }
    }

    // MARK: - 最新心率

    /// 优先返回 Apple Watch 记录的最新心率；没有 Apple Watch 样本时才返回其他来源的最新一条
    /// （`HeartRateSample.source.isAppleWatch` 为 `false`，界面会标注来源）。
    public func fetchLatestHeartRate() async throws -> HeartRateSample? {
        let heartRate = HKQuantityType(.heartRate)
        let appleWatchOnly = HKQuery.predicateForObjects(withDeviceProperty: HKDevicePropertyKeyModel, allowedValues: ["Watch"])
        if let sample = try await latestQuantitySample(of: heartRate, predicate: appleWatchOnly) {
            return Self.makeHeartRateSample(from: sample)
        }
        // 空结果可能是“确实没有记录”，也可能是“读取权限被拒绝”，HealthKit 不区分二者。
        return try await latestQuantitySample(of: heartRate).map(Self.makeHeartRateSample(from:))
    }

    static func makeHeartRateSample(from sample: HKQuantitySample) -> HeartRateSample {
        let sourceRevision = sample.sourceRevision
        let unit = HealthKitTypes.beatsPerMinute
        return HeartRateSample(
            id: sample.uuid,
            beatsPerMinute: sample.quantity.doubleValue(for: unit),
            unit: unit.unitString,
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

    // MARK: - 摘要

    public func fetchSummary(for kind: HealthMetricKind, on day: Date) async throws -> MetricSummaryValue? {
        switch kind.aggregation {
        case .discrete:
            guard let type = kind.quantityType,
                  let sample = try await latestQuantitySample(of: type) else { return nil }
            return MetricSummaryValue(
                kind: kind,
                value: sample.quantity.doubleValue(for: kind.healthKitUnit),
                date: sample.endDate,
                sourceName: sample.sourceRevision.source.name
            )

        case .cumulative:
            guard let type = kind.quantityType else { return nil }
            let dayStart = calendar.startOfDay(for: day)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
            let descriptor = HKStatisticsQueryDescriptor(
                predicate: .quantitySample(
                    type: type,
                    predicate: HKQuery.predicateForSamples(withStart: dayStart, end: dayEnd)
                ),
                options: .cumulativeSum
            )
            let statistics: HKStatistics?
            do {
                statistics = try await descriptor.result(for: healthStore)
            } catch {
                throw HealthKitErrorMapping.map(error, whileAuthorizing: false)
            }
            guard let sum = statistics?.sumQuantity() else { return nil }
            return MetricSummaryValue(kind: kind, value: sum.doubleValue(for: kind.healthKitUnit), date: dayStart)

        case .sleep:
            let dayStart = calendar.startOfDay(for: day)
            let interval = DateInterval(start: dayStart, end: calendar.date(byAdding: .day, value: 1, to: dayStart)!)
            guard let night = try await sleepNights(in: interval).first(where: { $0.date == dayStart }) else {
                return nil
            }
            return MetricSummaryValue(
                kind: .sleep,
                value: night.primaryDuration / 3600,
                date: night.end,
                sourceName: night.sourceNames.first,
                sleepNight: night
            )
        }
    }

    // MARK: - 趋势

    public func fetchDailyTrend(for kind: HealthMetricKind, in interval: DateInterval) async throws -> [MetricDataPoint] {
        if kind.aggregation == .sleep {
            return try await sleepNights(in: interval).map {
                MetricDataPoint(date: $0.date, value: $0.primaryDuration / 3600)
            }
        }
        guard let type = kind.quantityType else { return [] }

        let isDiscrete = kind.aggregation == .discrete
        let anchor = calendar.startOfDay(for: interval.start)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: type,
                predicate: HKQuery.predicateForSamples(withStart: interval.start, end: interval.end)
            ),
            options: isDiscrete ? [.discreteAverage, .discreteMin, .discreteMax] : .cumulativeSum,
            anchorDate: anchor,
            intervalComponents: DateComponents(day: 1)
        )

        let collection: HKStatisticsCollection
        do {
            collection = try await descriptor.result(for: healthStore)
        } catch {
            throw HealthKitErrorMapping.map(error, whileAuthorizing: false)
        }

        let unit = kind.healthKitUnit
        return collection.statistics().compactMap { statistics -> MetricDataPoint? in
            guard statistics.startDate >= interval.start, statistics.startDate < interval.end else { return nil }
            if isDiscrete {
                guard let average = statistics.averageQuantity() else { return nil }
                return MetricDataPoint(
                    date: statistics.startDate,
                    value: average.doubleValue(for: unit),
                    minimum: statistics.minimumQuantity()?.doubleValue(for: unit),
                    maximum: statistics.maximumQuantity()?.doubleValue(for: unit)
                )
            }
            guard let sum = statistics.sumQuantity() else { return nil }
            return MetricDataPoint(date: statistics.startDate, value: sum.doubleValue(for: unit))
        }
    }

    // MARK: - Private

    private func latestQuantitySample(of type: HKQuantityType, predicate: NSPredicate? = nil) async throws -> HKQuantitySample? {
        guard isHealthDataAvailable else { throw HealthDataError.healthDataUnavailable }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)],
            limit: 1
        )
        do {
            return try await descriptor.result(for: healthStore).first
        } catch {
            throw HealthKitErrorMapping.map(error, whileAuthorizing: false)
        }
    }

    /// 读取 `interval` 内各夜（按醒来日期）的睡眠汇总。
    private func sleepNights(in interval: DateInterval) async throws -> [SleepNight] {
        guard isHealthDataAvailable else { throw HealthDataError.healthDataUnavailable }
        // 夜的归属以 18:00 为界，因此需要从区间起点前一天 18:00 开始查询。
        let queryStart = interval.start.addingTimeInterval(-6 * 3600)
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(
                type: HKCategoryType(.sleepAnalysis),
                predicate: HKQuery.predicateForSamples(withStart: queryStart, end: interval.end)
            )],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let samples: [HKCategorySample]
        do {
            samples = try await descriptor.result(for: healthStore)
        } catch {
            throw HealthKitErrorMapping.map(error, whileAuthorizing: false)
        }
        let segments = samples.compactMap { sample -> SleepSegment? in
            guard let stage = SleepStage(healthKitValue: sample.value) else { return nil }
            return SleepSegment(
                start: sample.startDate,
                end: sample.endDate,
                stage: stage,
                sourceName: sample.sourceRevision.source.name
            )
        }
        return SleepAggregator.nights(from: segments, calendar: calendar)
            .filter { interval.contains($0.date) && $0.date < interval.end }
    }
}
#endif
