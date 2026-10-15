import Foundation
import XCTest
import WatchPulseCore
import WatchPulseShared

@MainActor
final class HealthInsightsViewModelTests: XCTestCase {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 9))!

    private func makeViewModel(_ service: MockHealthDataService) -> HealthInsightsViewModel {
        let now = Self.now
        return HealthInsightsViewModel(service: service, calendar: Self.calendar, now: { now })
    }

    private func dailyPoints(days: ClosedRange<Int>, value: Double) -> [MetricDataPoint] {
        let today = Self.calendar.startOfDay(for: Self.now)
        return days.map { MetricDataPoint(date: Self.calendar.date(byAdding: .day, value: -$0, to: today)!, value: value) }
    }

    func testDemoDataLoadsAllCards() async throws {
        let viewModel = makeViewModel(.demo(now: Self.now, calendar: Self.calendar))
        await viewModel.load()
        let snapshot = try XCTUnwrap(viewModel.state.value)
        XCTAssertEqual(snapshot.restingHeartRate.value?.sufficiency, .sufficient)
        XCTAssertEqual(snapshot.heartRateVariability.value?.sufficiency, .sufficient)
        XCTAssertNotNil(snapshot.sleep.value?.latestNight)
        XCTAssertNotNil(snapshot.sleep.value?.regularity)
        XCTAssertEqual(snapshot.generatedAt, Self.now)

        XCTAssertEqual(viewModel.trendDays(for: .restingHeartRate).count, 7)
        viewModel.trendRange = .fourWeeks
        XCTAssertEqual(viewModel.trendDays(for: .restingHeartRate).count, 28)
        XCTAssertEqual(viewModel.trendDays(for: .sleep).count, 28)
    }

    func testEmptyIsNoDataNotDenied() async {
        let viewModel = makeViewModel(MockHealthDataService())
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .noData)
    }

    func testNeedsAuthorizationDoesNotPrompt() async {
        let service = MockHealthDataService.demo(now: Self.now, calendar: Self.calendar)
        service.authorizationStatus = .shouldRequest
        let viewModel = makeViewModel(service)
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .needsAuthorization)
        XCTAssertEqual(service.authorizationRequestCount, 0)

        await viewModel.requestAuthorizationAndLoad()
        XCTAssertEqual(service.authorizationRequestCount, 1)
        XCTAssertNotNil(viewModel.state.value)
    }

    func testUnavailable() async {
        let viewModel = makeViewModel(MockHealthDataService(isHealthDataAvailable: false))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .healthDataUnavailable)
    }

    func testPartialFailureKeepsOtherCards() async throws {
        let service = MockHealthDataService.demo(now: Self.now, calendar: Self.calendar)
        service.setTrend(.failure(.queryFailed(reason: "test")), for: .heartRateVariability)
        let viewModel = makeViewModel(service)
        await viewModel.load()
        let snapshot = try XCTUnwrap(viewModel.state.value)
        XCTAssertEqual(snapshot.heartRateVariability, .failed(.queryFailed(reason: "test")))
        XCTAssertNotNil(snapshot.restingHeartRate.value)
        XCTAssertNotNil(snapshot.sleep.value)
    }

    func testAllFailuresIsFailed() async {
        let error = HealthDataError.protectedDataUnavailable
        let service = MockHealthDataService(
            trends: [.restingHeartRate: .failure(error), .heartRateVariability: .failure(error)],
            sleepNights: .failure(error)
        )
        let viewModel = makeViewModel(service)
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .failed(error))
    }

    func testInsufficientDataIsReportedNotComputed() async throws {
        let service = MockHealthDataService(trends: [
            .restingHeartRate: .value(dailyPoints(days: 1...10, value: 60)),
        ])
        let viewModel = makeViewModel(service)
        await viewModel.load()
        let snapshot = try XCTUnwrap(viewModel.state.value)
        let resting = try XCTUnwrap(snapshot.restingHeartRate.value)
        XCTAssertEqual(resting.sufficiency, .insufficient(referenceDays: 3, observationDays: 7))
        XCTAssertNil(resting.delta)
        XCTAssertEqual(snapshot.heartRateVariability, .noData)
        XCTAssertEqual(snapshot.sleep, .noData)
    }

    func testMissingDaysStayMissingInTrend() async throws {
        let service = MockHealthDataService(trends: [
            .restingHeartRate: .value(dailyPoints(days: 1...3, value: 60) + dailyPoints(days: 6...6, value: 61)),
        ])
        let viewModel = makeViewModel(service)
        await viewModel.load()
        let days = viewModel.trendDays(for: .restingHeartRate)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.compactMap(\.value).count, 4)
        XCTAssertNil(days.last?.value, "今天没有数据时为缺测，不是 0")
    }
}
