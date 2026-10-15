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

    func testInitialStateIsIdle() async {
        let viewModel = makeViewModel(MockHealthDataService())
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.lastCheckedAt)
    }

    func testUnavailableDeviceDoesNotTouchHealthData() async {
        let service = MockHealthDataService(isHealthDataAvailable: false, fetchBehavior: .sample(.previewSample()))
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .healthDataUnavailable)
        XCTAssertEqual(service.fetchCount, 0)
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

        XCTAssertEqual(viewModel.state, .loaded(sample))
        XCTAssertEqual(viewModel.lastCheckedAt, fixedNow)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testUnknownAuthorizationStatusStillAttemptsRead() async {
        let sample = HeartRateSample.previewSample()
        let service = MockHealthDataService(authorizationStatus: .unknown, fetchBehavior: .sample(sample))
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .loaded(sample))
        XCTAssertEqual(service.fetchCount, 1)
    }

    func testEmptyResultIsNoDataNotFailure() async {
        let service = MockHealthDataService(authorizationStatus: .unnecessary, fetchBehavior: .noData)
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .noData)
        XCTAssertEqual(viewModel.lastCheckedAt, fixedNow)
    }

    func testQueryErrorIsFailure() async {
        let service = MockHealthDataService(fetchBehavior: .failure(.protectedDataUnavailable))
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .failed(.protectedDataUnavailable))
        XCTAssertNil(viewModel.lastCheckedAt)
    }

    func testUnavailableErrorFromServiceMapsToUnavailableState() async {
        let service = MockHealthDataService(fetchBehavior: .failure(.healthDataUnavailable))
        let viewModel = makeViewModel(service)

        await viewModel.load()

        XCTAssertEqual(viewModel.state, .healthDataUnavailable)
    }

    func testRequestAuthorizationThenReads() async {
        let sample = HeartRateSample.previewSample()
        let service = MockHealthDataService(authorizationStatus: .shouldRequest, fetchBehavior: .sample(sample))
        let viewModel = makeViewModel(service)

        await viewModel.load()
        XCTAssertEqual(viewModel.state, .needsAuthorization)

        await viewModel.requestAuthorizationAndLoad()

        XCTAssertEqual(service.authorizationRequestCount, 1)
        XCTAssertEqual(viewModel.state, .loaded(sample))

        // 再次加载不应再要求授权。
        await viewModel.load()
        XCTAssertEqual(service.authorizationRequestCount, 1)
        XCTAssertEqual(viewModel.state, .loaded(sample))
    }

    func testAuthorizationCompletedButNoReadableDataIsNoData() async {
        // 用户在授权框里关闭了心率读取时，HealthKit 依旧“成功”返回，查询结果为空。
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
        let service = MockHealthDataService(fetchBehavior: .failure(.queryFailed(reason: "boom")))
        let viewModel = makeViewModel(service)

        await viewModel.load()
        XCTAssertEqual(viewModel.state, .failed(.queryFailed(reason: "boom")))

        let sample = HeartRateSample.previewSample()
        service.fetchBehavior = .sample(sample)
        await viewModel.load()

        XCTAssertEqual(viewModel.state, .loaded(sample))
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
}
