import Foundation
import XCTest
@testable import WatchPulseCore
import WatchPulseShared

@MainActor
final class HealthOverviewViewModelTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeViewModel(_ service: MockHealthDataService) -> HealthOverviewViewModel {
        let now = fixedNow
        return HealthOverviewViewModel(service: service, now: { now })
    }

    private func summary(_ kind: HealthMetricKind, _ value: Double) -> MockHealthDataService.Behavior<MetricSummaryValue> {
        .value(MetricSummaryValue(kind: kind, value: value, date: fixedNow))
    }

    func testInitialStateIsIdle() async {
        let viewModel = makeViewModel(MockHealthDataService())
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.lastCheckedAt)
        XCTAssertEqual(viewModel.dataOrigin, .simulated)
    }

    func testUnavailableDeviceDoesNotTouchHealthData() async {
        let service = MockHealthDataService(isHealthDataAvailable: false, fetchBehavior: .sample(.previewSample()))
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .healthDataUnavailable)
        XCTAssertEqual(service.fetchCount, 0)
        XCTAssertEqual(service.summaryFetchCount, 0)
        XCTAssertEqual(service.authorizationRequestCount, 0)
    }

    func testLoadDoesNotPromptAuthorizationAutomatically() async {
        let service = MockHealthDataService(authorizationStatus: .shouldRequest, fetchBehavior: .sample(.previewSample()))
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .needsAuthorization)
        XCTAssertEqual(service.authorizationRequestCount, 0)
        XCTAssertEqual(service.fetchCount, 0)
        XCTAssertNil(viewModel.lastCheckedAt)
    }

    func testLoadShowsLatestSampleWhenAlreadyAuthorized() async {
        let sample = HeartRateSample.previewSample(beatsPerMinute: 64)
        let service = MockHealthDataService(authorizationStatus: .unnecessary, fetchBehavior: .sample(sample))
        let viewModel = makeViewModel(service)

        await viewModel.load()

        let snapshot = try? XCTUnwrap(viewModel.state.value)
        XCTAssertEqual(snapshot?.latestHeartRate, sample)
        XCTAssertEqual(snapshot?.cards.map(\.kind), HealthDashboardSnapshot.cardKinds)
        XCTAssertTrue(snapshot?.cards.allSatisfy { $0.status == .noData } ?? false)
        XCTAssertEqual(viewModel.lastCheckedAt, fixedNow)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testLoadsAllMetricCards() async {
        let service = MockHealthDataService(
            summaries: [
                .restingHeartRate: summary(.restingHeartRate, 55),
                .heartRateVariability: summary(.heartRateVariability, 42),
                .stepCount: summary(.stepCount, 8_000),
                .activeEnergy: summary(.activeEnergy, 300),
                .sleep: summary(.sleep, 7.5),
            ]
        )
        let viewModel = makeViewModel(service)

        await viewModel.load()

        let snapshot = viewModel.state.value
        XCTAssertNil(snapshot?.latestHeartRate)
        XCTAssertEqual(snapshot?.card(for: .stepCount)?.status, .value(MetricSummaryValue(kind: .stepCount, value: 8_000, date: fixedNow)))
        XCTAssertEqual(service.summaryFetchCount, HealthDashboardSnapshot.cardKinds.count)
    }

    func testUnknownAuthorizationStatusStillAttemptsRead() async {
        let sample = HeartRateSample.previewSample()
        let service = MockHealthDataService(authorizationStatus: .unknown, fetchBehavior: .sample(sample))
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.state.value?.latestHeartRate, sample)
        XCTAssertEqual(service.fetchCount, 1)
    }

    func testEmptyResultIsNoDataNotFailure() async {
        let service = MockHealthDataService(authorizationStatus: .unnecessary, fetchBehavior: .noData)
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .noData)
        XCTAssertEqual(viewModel.lastCheckedAt, fixedNow)
    }

    func testSingleMetricFailureDoesNotHideOthers() async {
        let service = MockHealthDataService(
            fetchBehavior: .failure(.queryFailed(reason: "hr")),
            summaries: [
                .stepCount: summary(.stepCount, 1_234),
                .sleep: .failure(.queryFailed(reason: "sleep")),
            ]
        )
        let viewModel = makeViewModel(service)

        await viewModel.load()

        let snapshot = viewModel.state.value
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.heartRateError, .queryFailed(reason: "hr"))
        XCTAssertEqual(snapshot?.card(for: .sleep)?.status, .failed(.queryFailed(reason: "sleep")))
        XCTAssertEqual(snapshot?.card(for: .restingHeartRate)?.status, .noData)
    }

    func testAllQueriesFailingIsFailure() async {
        let error = HealthDataError.protectedDataUnavailable
        var summaries: [HealthMetricKind: MockHealthDataService.Behavior<MetricSummaryValue>] = [:]
        for kind in HealthDashboardSnapshot.cardKinds {
            summaries[kind] = .failure(error)
        }
        let service = MockHealthDataService(fetchBehavior: .failure(error), summaries: summaries)
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .failed(error))
        XCTAssertNil(viewModel.lastCheckedAt)
    }

    func testAllQueriesUnavailableMapsToUnavailableState() async {
        var summaries: [HealthMetricKind: MockHealthDataService.Behavior<MetricSummaryValue>] = [:]
        for kind in HealthDashboardSnapshot.cardKinds {
            summaries[kind] = .failure(.healthDataUnavailable)
        }
        let service = MockHealthDataService(fetchBehavior: .failure(.healthDataUnavailable), summaries: summaries)
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .healthDataUnavailable)
    }

    func testAuthorizationStatusErrorIsFailure() async {
        let error = HealthDataError.authorizationFailed(reason: "status")
        let service = FailingStatusService(error: error)
        let viewModel = HealthOverviewViewModel(service: service)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .failed(error))
    }

    func testRequestAuthorizationThenReads() async {
        let sample = HeartRateSample.previewSample()
        let service = MockHealthDataService(authorizationStatus: .shouldRequest, fetchBehavior: .sample(sample))
        let viewModel = makeViewModel(service)

        await viewModel.load()
        XCTAssertEqual(viewModel.state, .needsAuthorization)

        await viewModel.requestAuthorizationAndLoad()

        XCTAssertEqual(service.authorizationRequestCount, 1)
        XCTAssertEqual(viewModel.state.value?.latestHeartRate, sample)

        // 再次加载不应再要求授权。
        await viewModel.load()
        XCTAssertEqual(service.authorizationRequestCount, 1)
        XCTAssertEqual(viewModel.state.value?.latestHeartRate, sample)
    }

    func testAuthorizationCompletedButNoReadableDataIsNoData() async {
        // 用户在授权框里关闭了全部读取权限时，HealthKit 依旧“成功”返回，查询结果为空。
        let service = MockHealthDataService(authorizationStatus: .shouldRequest, fetchBehavior: .noData)
        let viewModel = makeViewModel(service)

        await viewModel.requestAuthorizationAndLoad()

        XCTAssertEqual(viewModel.state, .noData)
    }

    func testAuthorizationErrorIsFailure() async {
        let error = HealthDataError.authorizationFailed(reason: "missing usage description")
        let service = MockHealthDataService(authorizationStatus: .shouldRequest, authorizationError: error)
        let viewModel = makeViewModel(service)

        await viewModel.requestAuthorizationAndLoad()

        XCTAssertEqual(viewModel.state, .failed(error))
        XCTAssertEqual(service.fetchCount, 0)
    }

    func testRefreshRecoversFromFailure() async {
        var summaries: [HealthMetricKind: MockHealthDataService.Behavior<MetricSummaryValue>] = [:]
        for kind in HealthDashboardSnapshot.cardKinds {
            summaries[kind] = .failure(.queryFailed(reason: "boom"))
        }
        let service = MockHealthDataService(fetchBehavior: .failure(.queryFailed(reason: "boom")), summaries: summaries)
        let viewModel = makeViewModel(service)

        await viewModel.load()
        XCTAssertEqual(viewModel.state, .failed(.queryFailed(reason: "boom")))

        let sample = HeartRateSample.previewSample()
        service.fetchBehavior = .sample(sample)
        await viewModel.load()

        XCTAssertEqual(viewModel.state.value?.latestHeartRate, sample)
    }

    func testConcurrentLoadsAreCoalesced() async {
        let service = MockHealthDataService(fetchBehavior: .noData, responseDelay: .milliseconds(50))
        let viewModel = makeViewModel(service)

        async let first: Void = viewModel.load()
        async let second: Void = viewModel.load()
        _ = await (first, second)

        XCTAssertEqual(service.fetchCount, 1)
        XCTAssertEqual(viewModel.state, .noData)
    }

    func testDemoServiceProducesFullDashboard() async {
        let service = MockHealthDataService.demo(now: fixedNow)
        let viewModel = makeViewModel(service)

        await viewModel.load()

        let snapshot = viewModel.state.value
        XCTAssertEqual(snapshot?.latestHeartRate?.source.name, SimulatedHealthData.sourceName)
        for kind in HealthDashboardSnapshot.cardKinds {
            guard case .value(let value)? = snapshot?.card(for: kind)?.status else {
                return XCTFail("missing \(kind)")
            }
            XCTAssertEqual(value.sourceName, SimulatedHealthData.sourceName)
        }
    }
}

/// 授权状态查询本身抛错的服务。
private final class FailingStatusService: HealthDataService {
    let error: HealthDataError
    init(error: HealthDataError) { self.error = error }

    var dataOrigin: HealthDataOrigin { .simulated }
    var isHealthDataAvailable: Bool { true }
    func authorizationRequestStatus() async throws -> HealthAuthorizationRequestStatus { throw error }
    func requestAuthorization() async throws {}
    func fetchLatestHeartRate() async throws -> HeartRateSample? { nil }
    func fetchSummary(for kind: HealthMetricKind, on day: Date) async throws -> MetricSummaryValue? { nil }
    func fetchDailyTrend(for kind: HealthMetricKind, in interval: DateInterval) async throws -> [MetricDataPoint] { [] }
    func fetchSleepNights(in interval: DateInterval) async throws -> [SleepNight] { [] }
}
