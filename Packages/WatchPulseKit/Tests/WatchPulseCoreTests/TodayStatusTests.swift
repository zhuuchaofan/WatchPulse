import Foundation
import XCTest
@testable import WatchPulseCore
import WatchPulseShared

final class TodayStatusTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 2026-06-04 12:00 UTC。
    private let now = Date(timeIntervalSince1970: 1_780_574_400)

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    /// 最近 7 天每天 `observation`，此前 `referenceDays` 天每天 `reference`。
    private func baseline(
        _ kind: HealthMetricKind,
        reference: Double,
        observation: Double,
        referenceDays: Int = 28
    ) -> BaselineComparison {
        let windows = BaselineWindows(asOf: now, calendar: calendar)
        var points = (1...7).map { MetricDataPoint(date: day(-$0), value: observation) }
        points += (8..<(8 + referenceDays)).map { MetricDataPoint(date: day(-$0), value: reference) }
        let series = DailyMetricSeries(kind: kind, points: points, interval: windows.fullInterval, calendar: calendar)
        return BaselineComparison(kind: kind, daily: series, windows: windows)
    }

    private func card(_ kind: HealthMetricKind, _ baseline: BaselineComparison?) -> MetricCardModel {
        MetricCardModel(kind: kind, status: .noData, baseline: baseline)
    }

    private func snapshot(_ cards: [MetricCardModel]) -> HealthDashboardSnapshot {
        HealthDashboardSnapshot(latestHeartRate: nil, cards: cards)
    }

    func testSteadyWhenAllComparisonsAreFlat() {
        let status = TodayStatus.make(from: snapshot([
            card(.restingHeartRate, baseline(.restingHeartRate, reference: 60, observation: 60)),
            card(.heartRateVariability, baseline(.heartRateVariability, reference: 50, observation: 50)),
        ]))
        XCTAssertEqual(status.level, .steady)
        XCTAssertEqual(status.headline, "和平时差不多")
        XCTAssertEqual(status.action, .openTraining)
        XCTAssertTrue(status.reason.contains("静息心率和心率变异性"))
    }

    func testChangedDescribesDifferenceAgainstOwnUsualOnly() {
        let status = TodayStatus.make(from: snapshot([
            card(.restingHeartRate, baseline(.restingHeartRate, reference: 60, observation: 64)),
            card(.heartRateVariability, baseline(.heartRateVariability, reference: 50, observation: 50)),
        ]))
        XCTAssertEqual(status.level, .changed)
        XCTAssertEqual(status.headline, "和平时有些不同")
        XCTAssertTrue(status.reason.contains("静息心率比平时高 4 次/分"), status.reason)
        XCTAssertFalse(status.reason.contains("心率变异性比平时"), "持平的指标不列入差异")
        XCTAssertTrue(status.reason.contains("不代表健康状况"))
        XCTAssertEqual(status.action, .openTrend(.restingHeartRate))
        XCTAssertEqual(status.action.title, "查看静息心率变化")
    }

    func testLowerIsDescribedAsLowerAndLinksToThatMetric() {
        let status = TodayStatus.make(from: snapshot([
            card(.restingHeartRate, baseline(.restingHeartRate, reference: 60, observation: 60)),
            card(.heartRateVariability, baseline(.heartRateVariability, reference: 50, observation: 40)),
        ]))
        XCTAssertTrue(status.reason.contains("心率变异性比平时低 10 毫秒"), status.reason)
        XCTAssertEqual(status.action, .openTrend(.heartRateVariability))
    }

    func testInsufficientBaselineIsLearningNotSteady() {
        let status = TodayStatus.make(from: snapshot([
            card(.restingHeartRate, baseline(.restingHeartRate, reference: 60, observation: 60, referenceDays: 5)),
        ]))
        XCTAssertEqual(status.level, .learning)
        XCTAssertFalse(status.headline.contains("差不多"), "数据不足不能说成与平时一样")
        XCTAssertEqual(status.headline, "正在了解你的平时水平")
    }

    func testNoComparableMetricsIsLimited() {
        let status = TodayStatus.make(from: snapshot([card(.stepCount, nil), card(.sleep, nil)]))
        XCTAssertEqual(status.level, .limited)
        XCTAssertEqual(status.headline, "今天的数据还不多")
    }

    func testWordingAvoidsMedicalImplications() {
        let statuses = [
            TodayStatus.make(from: snapshot([card(.restingHeartRate, baseline(.restingHeartRate, reference: 60, observation: 70))])),
            TodayStatus.make(from: snapshot([card(.restingHeartRate, baseline(.restingHeartRate, reference: 60, observation: 60))])),
            TodayStatus.make(from: snapshot([card(.restingHeartRate, baseline(.restingHeartRate, reference: 60, observation: 60, referenceDays: 3))])),
            TodayStatus.make(from: snapshot([])),
        ]
        for status in statuses {
            for word in ["异常", "疾病", "过劳", "恢复", "压力", "风险", "诊断", "基线", "中位数"] {
                XCTAssertFalse((status.headline + status.reason).contains(word), "\(status.headline) \(status.reason) 不应包含 \(word)")
            }
        }
    }

    func testPlainShortText() {
        XCTAssertEqual(baseline(.restingHeartRate, reference: 60, observation: 63).plainShortText, "比平时高 3")
        XCTAssertEqual(baseline(.restingHeartRate, reference: 60, observation: 57).plainShortText, "比平时低 3")
        XCTAssertEqual(baseline(.restingHeartRate, reference: 60, observation: 60).plainShortText, "和平时差不多")
        XCTAssertEqual(baseline(.restingHeartRate, reference: 60, observation: 60, referenceDays: 3).plainShortText, "还在了解你的平时水平")
    }
}
