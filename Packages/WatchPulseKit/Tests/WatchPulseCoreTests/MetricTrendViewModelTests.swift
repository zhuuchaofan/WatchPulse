import Foundation
import XCTest
@testable import WatchPulseCore
import WatchPulseShared

@MainActor
final class MetricTrendViewModelTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-15 06:13 +08:00

    private func days(_ count: Int, value: Double = 1) -> [MetricDataPoint] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).map { offset in
            MetricDataPoint(date: calendar.date(byAdding: .day, value: -offset, to: today)!, value: value + Double(offset))
        }
    }

    private func makeViewModel(_ service: MockHealthDataService, kind: HealthMetricKind = .stepCount) -> MetricTrendViewModel {
        let now = now
        return MetricTrendViewModel(kind: kind, service: service, calendar: calendar, now: { now })
    }

    func testLoadsWeekTrendWithStatistics() async {
        let service = MockHealthDataService(trends: [.stepCount: .value(days(30, value: 100))])
        let viewModel = makeViewModel(service)

        await viewModel.load()

        let trend = viewModel.state.value
        XCTAssertEqual(trend?.points.count, 7)
        XCTAssertEqual(trend?.period, .week)
        XCTAssertEqual(trend?.points.first?.value, 106) // 最早的一天在前
        XCTAssertEqual(trend?.statistics?.minimum, 100)
        XCTAssertEqual(trend?.statistics?.maximum, 106)
        XCTAssertEqual(trend?.statistics?.total, 721)
        XCTAssertEqual(trend?.statistics?.dayCount, 7)
    }

    func testSwitchingPeriodReloads() async {
        let service = MockHealthDataService(trends: [.stepCount: .value(days(120))])
        let viewModel = makeViewModel(service)

        await viewModel.load()
        await viewModel.select(.quarter)

        XCTAssertEqual(viewModel.period, .quarter)
        XCTAssertEqual(viewModel.state.value?.points.count, 90)
        XCTAssertEqual(service.trendFetchCount, 2)

        // 选择相同范围不重复加载。
        await viewModel.select(.quarter)
        XCTAssertEqual(service.trendFetchCount, 2)
    }

    func testEmptyTrendIsNoData() async {
        let viewModel = makeViewModel(MockHealthDataService())
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .noData)
    }

    func testFailure() async {
        let service = MockHealthDataService(trends: [.sleep: .failure(.queryFailed(reason: "x"))])
        let viewModel = makeViewModel(service, kind: .sleep)
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .failed(.queryFailed(reason: "x")))
    }

    func testUnavailable() async {
        let viewModel = makeViewModel(MockHealthDataService(isHealthDataAvailable: false))
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .healthDataUnavailable)
    }

    func testDemoDataCoversEveryMetricAndPeriod() async {
        let service = MockHealthDataService.demo(now: now, calendar: calendar)
        for kind in HealthMetricKind.allCases {
            for period in TrendPeriod.allCases {
                let viewModel = MetricTrendViewModel(kind: kind, period: period, service: service, calendar: calendar, now: { [now] in now })
                await viewModel.load()
                XCTAssertEqual(viewModel.state.value?.points.count, period.dayCount, "\(kind) \(period)")
            }
        }
    }

    func testDemoDataIsDeterministic() async {
        let first = SimulatedHealthData(now: now, calendar: calendar).trend(for: .stepCount, days: 30)
        let second = SimulatedHealthData(now: now, calendar: calendar).trend(for: .stepCount, days: 30)
        XCTAssertEqual(first, second)
    }
}
