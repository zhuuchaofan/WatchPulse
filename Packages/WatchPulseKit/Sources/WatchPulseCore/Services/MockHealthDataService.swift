import Foundation
import WatchPulseShared

/// 仅用于 SwiftUI Preview 与单元测试的健康数据服务。
///
/// 它不会读取任何真实健康数据；`HeartRateSample.previewSample` 的来源名明确标注为预览数据，
/// 不得用于真机验收。
public final class MockHealthDataService: HealthDataService, @unchecked Sendable {
    /// `fetchLatestHeartRate()` 的返回行为。
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
    private var _responseDelay: Duration?
    private var _authorizationRequestCount = 0
    private var _fetchCount = 0

    public init(
        isHealthDataAvailable: Bool = true,
        authorizationStatus: HealthAuthorizationRequestStatus = .unnecessary,
        authorizationError: HealthDataError? = nil,
        fetchBehavior: FetchBehavior = .noData,
        responseDelay: Duration? = nil
    ) {
        _isHealthDataAvailable = isHealthDataAvailable
        _authorizationStatus = authorizationStatus
        _authorizationError = authorizationError
        _fetchBehavior = fetchBehavior
        _responseDelay = responseDelay
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

    // MARK: - 调用记录

    public var authorizationRequestCount: Int { withLock { _authorizationRequestCount } }
    public var fetchCount: Int { withLock { _fetchCount } }

    // MARK: - HealthDataService

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

    // MARK: - Private

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
                name: "预览示例数据（非真实）",
                bundleIdentifier: "preview.mock",
                productType: nil,
                deviceName: "Mock",
                deviceModel: "Mock"
            )
        )
    }
}
