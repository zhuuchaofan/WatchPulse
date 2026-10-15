import Foundation
import XCTest
import WatchPulseShared

final class HealthBaselineTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    /// 2026-04-30 09:00（上海）。
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 4, day: 30, hour: 9))! }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    /// 从今天往前 `daysAgo` 天的点（1 = 昨天）。
    private func points(_ values: [Int: Double]) -> [MetricDataPoint] {
        values.map { MetricDataPoint(date: day(-$0.key), value: $0.value) }
    }

    private func comparison(_ values: [Int: Double], kind: HealthMetricKind = .restingHeartRate) -> BaselineComparison {
        let windows = BaselineWindows(asOf: now, calendar: calendar)
        let series = DailyMetricSeries(kind: kind, points: points(values), interval: windows.fullInterval, calendar: calendar)
        return BaselineComparison(kind: kind, daily: series, windows: windows)
    }

    // MARK: - 窗口与每日序列

    func testWindowsExcludeTodayAndAreContiguous() {
        let windows = BaselineWindows(asOf: now, calendar: calendar)
        XCTAssertEqual(windows.observation.end, day(0))
        XCTAssertEqual(windows.observation.start, day(-7))
        XCTAssertEqual(windows.reference.end, day(-7))
        XCTAssertEqual(windows.reference.start, day(-35))
    }

    func testDailySeriesMarksMissingDays() {
        let interval = DateInterval(start: day(-5), end: day(0))
        let series = DailyMetricSeries(kind: .restingHeartRate, points: points([1: 60, 3: 62]), interval: interval, calendar: calendar)
        XCTAssertEqual(series.days.count, 5)
        XCTAssertEqual(series.validDayCount, 2)
        XCTAssertEqual(series.missingDayCount, 3)
        XCTAssertNil(series.days[0].value, "缺测日为 nil，不是 0")
        XCTAssertEqual(series.latestDate, day(-1))
        XCTAssertEqual(series.daysSinceLatest(asOf: now, calendar: calendar), 1)
    }

    func testDailySeriesAcrossDaylightSavingTransition() {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        // 2026-03-29 欧洲夏令时开始（当天 23 小时）。
        let start = berlin.date(from: DateComponents(year: 2026, month: 3, day: 27))!
        let end = berlin.date(from: DateComponents(year: 2026, month: 4, day: 1))!
        let points = (0..<5).map { offset -> MetricDataPoint in
            let date = berlin.date(byAdding: .day, value: offset, to: start)!
            return MetricDataPoint(date: date.addingTimeInterval(12 * 3600), value: Double(50 + offset))
        }
        let series = DailyMetricSeries(kind: .restingHeartRate, points: points, interval: DateInterval(start: start, end: end), calendar: berlin)
        XCTAssertEqual(series.days.count, 5, "夏令时切换日不能多出或缺少一天")
        XCTAssertEqual(series.validDayCount, 5)
        XCTAssertEqual(series.days.map(\.value), [50, 51, 52, 53, 54])
    }

    // MARK: - 基线

    func testNoDataIsInsufficientNotZero() {
        let result = comparison([:])
        XCTAssertEqual(result.sufficiency, .insufficient(referenceDays: 0, observationDays: 0))
        XCTAssertNil(result.delta)
        XCTAssertNil(result.referenceMedian)
        XCTAssertEqual(result.shortText, "基线积累中（0/14 天）")
    }

    func testExactlyAtThresholds() {
        var values: [Int: Double] = [:]
        for daysAgo in 8...21 { values[daysAgo] = 63 }  // 14 天参考
        for daysAgo in 1...4 { values[daysAgo] = 60 }   // 4 天观察
        let result = comparison(values)
        XCTAssertEqual(result.sufficiency, .sufficient)
        XCTAssertEqual(result.referenceMedian, 63)
        XCTAssertEqual(result.observationMedian, 60)
        XCTAssertEqual(result.delta, -3)
        XCTAssertEqual(result.direction, .down)
        XCTAssertEqual(result.shortText, "较基线 −3")
    }

    func testOneDayShortOfEitherThreshold() {
        var values: [Int: Double] = [:]
        for daysAgo in 8...20 { values[daysAgo] = 63 }  // 13 天
        for daysAgo in 1...7 { values[daysAgo] = 60 }
        XCTAssertEqual(comparison(values).sufficiency, .insufficient(referenceDays: 13, observationDays: 7))
        XCTAssertNil(comparison(values).delta)

        values = [:]
        for daysAgo in 8...35 { values[daysAgo] = 63 }
        for daysAgo in 1...3 { values[daysAgo] = 60 }   // 3 天
        let result = comparison(values)
        XCTAssertEqual(result.sufficiency, .insufficient(referenceDays: 28, observationDays: 3))
        XCTAssertEqual(result.shortText, "近期数据不足（3/4 天）")
    }

    func testTodayIsExcluded() {
        var values: [Int: Double] = [0: 90]  // 今天（不完整）
        for daysAgo in 8...35 { values[daysAgo] = 60 }
        for daysAgo in 1...7 { values[daysAgo] = 60 }
        let result = comparison(values)
        XCTAssertEqual(result.observationMedian, 60)
        XCTAssertEqual(result.observationDays, 7)
    }

    func testMedianIsRobustToOutliersAndImplausibleValuesExcluded() {
        var values: [Int: Double] = [:]
        for daysAgo in 8...35 { values[daysAgo] = 62 }
        values[10] = 140   // 合理范围内的极端值：中位数不受影响
        values[11] = 400   // 超出合理范围：排除
        for daysAgo in 1...7 { values[daysAgo] = 58 }
        values[2] = 0      // 超出合理范围：排除
        let result = comparison(values)
        XCTAssertEqual(result.referenceMedian, 62)
        XCTAssertEqual(result.observationMedian, 58)
        XCTAssertEqual(result.excludedDays, 2)
        XCTAssertEqual(result.referenceDays, 27)
        XCTAssertEqual(result.observationDays, 6)
    }

    func testMedianEvenCount() {
        XCTAssertEqual(BaselineComparison.median([1, 3, 2, 4]), 2.5)
        XCTAssertEqual(BaselineComparison.median([5]), 5)
        XCTAssertNil(BaselineComparison.median([]))
    }

    func testFlatAndUp() {
        var values: [Int: Double] = [:]
        for daysAgo in 8...35 { values[daysAgo] = 41 }
        for daysAgo in 1...7 { values[daysAgo] = 41.4 }
        XCTAssertEqual(comparison(values, kind: .heartRateVariability).direction, .flat)
        XCTAssertEqual(comparison(values, kind: .heartRateVariability).shortText, "与基线持平")
        for daysAgo in 1...7 { values[daysAgo] = 45 }
        let up = comparison(values, kind: .heartRateVariability)
        XCTAssertEqual(up.direction, .up)
        XCTAssertEqual(up.shortText, "较基线 +4")
        XCTAssertTrue(up.detailText.contains("近 7 天中位数 45 毫秒"))
        XCTAssertTrue(up.detailText.contains("基线（此前 28 天中位数）41 毫秒"))
    }

    func testTextsNeverContainDiagnosticWords() {
        var values: [Int: Double] = [:]
        for daysAgo in 8...35 { values[daysAgo] = 55 }
        for daysAgo in 1...7 { values[daysAgo] = 70 }
        let texts = [comparison(values).shortText, comparison(values).detailText, BaselineComparison.disclaimer]
        for word in ["生病", "过劳", "恢复", "疾病", "感染", "压力过大", "危险"] {
            XCTAssertFalse(texts.contains { $0.contains(word) }, "不应出现诊断性词语：\(word)")
        }
    }
}
