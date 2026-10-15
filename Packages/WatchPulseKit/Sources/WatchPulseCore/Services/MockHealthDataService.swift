import Foundation
import WatchPulseShared

/// 仅用于 SwiftUI Preview、单元测试与演示模式的健康数据服务。
///
/// 它不会读取任何真实健康数据，`dataOrigin` 固定为 `.simulated`，界面会据此标注“模拟数据”；
/// 示例样本的来源名也明确标注为非真实数据，不得用于真机验收。
public final class MockHealthDataService: HealthDataService, @unchecked Sendable {
    /// 单项查询的返回行为。
    public enum Behavior<Value: Sendable>: Sendable {
        case value(Value)
        case noData
        case failure(HealthDataError)
    }

    /// `fetchLatestHeartRate()` 的返回行为（保留第一阶段的写法）。
    public enum FetchBehavior: Sendable {
        case sample(HeartRateSample)
        case noData
        case failure(HealthDataError)
    }

    private let lock = NSLock()
    private var _isHealthDataAvailable: Bool
    private var _authorizationStatus: HealthAuthorizationRequestStatus
    private var _authorizationError: HealthDataError?
    private var _fetchBehavior: FetchBehavior
    private var _summaries: [HealthMetricKind: Behavior<MetricSummaryValue>]
    private var _trends: [HealthMetricKind: Behavior<[MetricDataPoint]>]
    private var _sleepNights: Behavior<[SleepNight]>
    private var _responseDelay: Duration?
    private var _authorizationRequestCount = 0
    private var _fetchCount = 0
    private var _summaryFetchCount = 0
    private var _trendFetchCount = 0

    public init(
        isHealthDataAvailable: Bool = true,
        authorizationStatus: HealthAuthorizationRequestStatus = .unnecessary,
        authorizationError: HealthDataError? = nil,
        fetchBehavior: FetchBehavior = .noData,
        summaries: [HealthMetricKind: Behavior<MetricSummaryValue>] = [:],
        trends: [HealthMetricKind: Behavior<[MetricDataPoint]>] = [:],
        sleepNights: Behavior<[SleepNight]> = .noData,
        responseDelay: Duration? = nil
    ) {
        _isHealthDataAvailable = isHealthDataAvailable
        _authorizationStatus = authorizationStatus
        _authorizationError = authorizationError
        _fetchBehavior = fetchBehavior
        _summaries = summaries
        _trends = trends
        _sleepNights = sleepNights
        _responseDelay = responseDelay
    }

    /// 演示模式：一整套确定性的模拟数据（非真实健康数据）。
    public static func demo(now: Date = Date(), calendar: Calendar = .current) -> MockHealthDataService {
        let data = SimulatedHealthData(now: now, calendar: calendar)
        return MockHealthDataService(
            fetchBehavior: .sample(data.latestHeartRate),
            summaries: Dictionary(uniqueKeysWithValues: HealthMetricKind.allCases.map { ($0, .value(data.summary(for: $0))) }),
            trends: Dictionary(uniqueKeysWithValues: HealthMetricKind.allCases.map { ($0, .value(data.trend(for: $0, days: 90))) }),
            sleepNights: .value(data.sleepNights(days: 30))
        )
    }

    // MARK: - 配置

    public var fetchBehavior: FetchBehavior {
        get { withLock { _fetchBehavior } }
        set { withLock { _fetchBehavior = newValue } }
    }

    public var authorizationStatus: HealthAuthorizationRequestStatus {
        get { withLock { _authorizationStatus } }
        set { withLock { _authorizationStatus = newValue } }
    }

    public func setSummary(_ behavior: Behavior<MetricSummaryValue>, for kind: HealthMetricKind) {
        withLock { _summaries[kind] = behavior }
    }

    public func setTrend(_ behavior: Behavior<[MetricDataPoint]>, for kind: HealthMetricKind) {
        withLock { _trends[kind] = behavior }
    }

    public func setSleepNights(_ behavior: Behavior<[SleepNight]>) {
        withLock { _sleepNights = behavior }
    }

    // MARK: - 调用记录

    public var authorizationRequestCount: Int { withLock { _authorizationRequestCount } }
    public var fetchCount: Int { withLock { _fetchCount } }
    public var summaryFetchCount: Int { withLock { _summaryFetchCount } }
    public var trendFetchCount: Int { withLock { _trendFetchCount } }

    // MARK: - HealthDataService

    public var dataOrigin: HealthDataOrigin { .simulated }

    public var isHealthDataAvailable: Bool { withLock { _isHealthDataAvailable } }

    public func authorizationRequestStatus() async throws -> HealthAuthorizationRequestStatus {
        try await simulateDelay()
        return withLock { _authorizationStatus }
    }

    public func requestAuthorization() async throws {
        try await simulateDelay()
        let error: HealthDataError? = withLock {
            _authorizationRequestCount += 1
            if _authorizationError == nil {
                // 模拟系统行为：授权框展示过之后无需再次请求。
                _authorizationStatus = .unnecessary
            }
            return _authorizationError
        }
        if let error { throw error }
    }

    public func fetchLatestHeartRate() async throws -> HeartRateSample? {
        try await simulateDelay()
        let behavior: FetchBehavior = withLock {
            _fetchCount += 1
            return _fetchBehavior
        }
        switch behavior {
        case .sample(let sample):
            return sample
        case .noData:
            return nil
        case .failure(let error):
            throw error
        }
    }

    public func fetchSummary(for kind: HealthMetricKind, on day: Date) async throws -> MetricSummaryValue? {
        try await simulateDelay()
        let behavior = withLock {
            _summaryFetchCount += 1
            return _summaries[kind] ?? .noData
        }
        return try Self.resolve(behavior)
    }

    public func fetchDailyTrend(for kind: HealthMetricKind, in interval: DateInterval) async throws -> [MetricDataPoint] {
        try await simulateDelay()
        let behavior = withLock {
            _trendFetchCount += 1
            return _trends[kind] ?? .noData
        }
        let points = try Self.resolve(behavior) ?? []
        return points.filter { interval.contains($0.date) && $0.date < interval.end }
    }

    public func fetchSleepNights(in interval: DateInterval) async throws -> [SleepNight] {
        try await simulateDelay()
        let behavior = withLock { _sleepNights }
        let nights = try Self.resolve(behavior) ?? []
        return nights.filter { $0.date >= interval.start && $0.date < interval.end }.sorted { $0.date < $1.date }
    }

    // MARK: - Private

    private static func resolve<Value>(_ behavior: Behavior<Value>) throws -> Value? {
        switch behavior {
        case .value(let value): return value
        case .noData: return nil
        case .failure(let error): throw error
        }
    }

    private func simulateDelay() async throws {
        if let delay = withLock({ _responseDelay }) {
            try await Task.sleep(for: delay)
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

extension HeartRateSample {
    /// Preview / 测试专用的示例样本，来源名称明确标注为非真实数据。
    public static func previewSample(
        beatsPerMinute: Double = 72,
        date: Date = Date(timeIntervalSinceReferenceDate: 800_000_000)
    ) -> HeartRateSample {
        HeartRateSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            beatsPerMinute: beatsPerMinute,
            startDate: date,
            endDate: date,
            source: HealthSampleSource(
                name: SimulatedHealthData.sourceName,
                bundleIdentifier: "preview.mock",
                productType: nil,
                deviceName: "Mock",
                deviceModel: "Mock"
            )
        )
    }
}
