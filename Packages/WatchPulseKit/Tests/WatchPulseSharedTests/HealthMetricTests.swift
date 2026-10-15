import Foundation
import XCTest
import WatchPulseShared

final class HealthMetricTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    // MARK: - 格式化

    func testFormatting() {
        XCTAssertEqual(MetricFormatting.grouped(0), "0")
        XCTAssertEqual(MetricFormatting.grouped(999), "999")
        XCTAssertEqual(MetricFormatting.grouped(8_234), "8,234")
        XCTAssertEqual(MetricFormatting.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(MetricFormatting.grouped(-4_500), "-4,500")
        XCTAssertEqual(MetricFormatting.duration(hours: 7.2), "7小时12分")
        XCTAssertEqual(MetricFormatting.duration(seconds: 42 * 60), "42分")
        XCTAssertEqual(MetricFormatting.duration(seconds: 3_900), "1小时05分")
        XCTAssertEqual(MetricFormatting.clock(seconds: 725), "12:05")
        XCTAssertEqual(MetricFormatting.clock(seconds: 3_723), "1:02:03")
        XCTAssertEqual(MetricFormatting.distance(meters: 820.4), "820 米")
        XCTAssertEqual(MetricFormatting.distance(meters: 3_254), "3.25 公里")
        XCTAssertEqual(MetricFormatting.distance(meters: 10_005), "10.01 公里")
    }

    func testMetricKindDisplay() {
        XCTAssertEqual(HealthMetricKind.stepCount.formattedValueWithUnit(8_234.4), "8,234 步")
        XCTAssertEqual(HealthMetricKind.heartRate.formattedValueWithUnit(71.6), "72 次/分")
        XCTAssertEqual(HealthMetricKind.heartRateVariability.formattedValueWithUnit(45.2), "45 毫秒")
        XCTAssertEqual(HealthMetricKind.sleep.formattedValueWithUnit(7.5), "7小时30分")
        XCTAssertEqual(HealthMetricKind.stepCount.aggregation, .cumulative)
        XCTAssertEqual(HealthMetricKind.restingHeartRate.aggregation, .discrete)
        for kind in HealthMetricKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.systemImage.isEmpty)
        }
    }

    // MARK: - 趋势区间与统计

    func testTrendPeriodInterval() {
        let now = date(15, 9, 30)
        let interval = TrendPeriod.week.interval(endingAt: now, calendar: calendar)
        XCTAssertEqual(interval.start, date(9, 0))
        XCTAssertEqual(interval.end, date(16, 0))
        XCTAssertEqual(TrendPeriod.month.interval(endingAt: now, calendar: calendar).duration, 30 * 86_400)
    }

    func testTrendStatisticsUsesMinMaxWhenPresent() {
        let points = [
            MetricDataPoint(date: date(1, 0), value: 70, minimum: 50, maximum: 120),
            MetricDataPoint(date: date(2, 0), value: 80, minimum: 55, maximum: 140),
        ]
        let statistics = MetricTrendStatistics(points: points)
        XCTAssertEqual(statistics?.average, 75)
        XCTAssertEqual(statistics?.minimum, 50)
        XCTAssertEqual(statistics?.maximum, 140)
        XCTAssertNil(MetricTrendStatistics(points: []))
    }

    // MARK: - 睡眠聚合

    func testSleepNightAssignmentUsesSixPMBoundary() {
        let lateNight = SleepSegment(start: date(10, 23), end: date(11, 7), stage: .core)
        let afterMidnight = SleepSegment(start: date(11, 1), end: date(11, 2), stage: .core)
        let afternoonNap = SleepSegment(start: date(11, 14), end: date(11, 15), stage: .core)
        let earlyEvening = SleepSegment(start: date(10, 19), end: date(10, 20), stage: .core)
        let beforeBoundary = SleepSegment(start: date(10, 17), end: date(10, 17, 30), stage: .core)

        XCTAssertEqual(SleepAggregator.nightDate(for: lateNight, calendar: calendar), date(11, 0))
        XCTAssertEqual(SleepAggregator.nightDate(for: afterMidnight, calendar: calendar), date(11, 0))
        XCTAssertEqual(SleepAggregator.nightDate(for: afternoonNap, calendar: calendar), date(11, 0))
        XCTAssertEqual(SleepAggregator.nightDate(for: earlyEvening, calendar: calendar), date(11, 0))
        XCTAssertEqual(SleepAggregator.nightDate(for: beforeBoundary, calendar: calendar), date(10, 0))
    }

    func testOverlappingSourcesAreNotDoubleCounted() {
        // iPhone 记录卧床 23:00–07:00；Apple Watch 记录的分期与之重叠；第三方 App 又记录了一段重复的睡眠。
        let segments = [
            SleepSegment(start: date(10, 23), end: date(11, 7), stage: .inBed, sourceName: "iPhone"),
            SleepSegment(start: date(10, 23, 30), end: date(11, 2), stage: .core, sourceName: "Watch"),
            SleepSegment(start: date(11, 2), end: date(11, 3), stage: .deep, sourceName: "Watch"),
            SleepSegment(start: date(11, 3), end: date(11, 3, 15), stage: .awake, sourceName: "Watch"),
            SleepSegment(start: date(11, 3, 15), end: date(11, 6, 30), stage: .rem, sourceName: "Watch"),
            SleepSegment(start: date(11, 1), end: date(11, 4), stage: .asleepUnspecified, sourceName: "App"),
        ]

        let nights = SleepAggregator.nights(from: segments, calendar: calendar)
        XCTAssertEqual(nights.count, 1)
        let night = nights[0]
        XCTAssertEqual(night.date, date(11, 0))
        XCTAssertEqual(night.inBedDuration, 8 * 3600)
        // 23:30–06:30 共 7 小时，其中 03:00–03:15 被“未细分睡眠”覆盖，优先于清醒，因此全部计为睡着。
        XCTAssertEqual(night.asleepDuration, 7 * 3600)
        XCTAssertEqual(night.awakeDuration, 0)
        XCTAssertEqual(night.stageDurations[.deep], 3600)
        XCTAssertEqual(night.stageDurations[.asleepUnspecified], 15 * 60)
        XCTAssertEqual(night.sourceNames, ["App", "Watch", "iPhone"])
        XCTAssertFalse(night.isInBedOnly)
        XCTAssertEqual(night.primaryDuration, night.asleepDuration)
    }

    func testInBedOnlyNight() {
        let nights = SleepAggregator.nights(
            from: [SleepSegment(start: date(10, 23), end: date(11, 6), stage: .inBed)],
            calendar: calendar
        )
        XCTAssertEqual(nights.first?.isInBedOnly, true)
        XCTAssertEqual(nights.first?.primaryDuration, 7 * 3600)
    }

    func testMultipleNightsSortedAndInvalidSegmentsIgnored() {
        let segments = [
            SleepSegment(start: date(12, 23), end: date(13, 6), stage: .core),
            SleepSegment(start: date(10, 23), end: date(11, 6), stage: .core),
            SleepSegment(start: date(11, 5), end: date(11, 5), stage: .core), // 零时长
            SleepSegment(start: date(11, 6), end: date(11, 5), stage: .core), // 结束早于开始
        ]
        let nights = SleepAggregator.nights(from: segments, calendar: calendar)
        XCTAssertEqual(nights.map(\.date), [date(11, 0), date(13, 0)])
    }

    /// 随机生成的睡眠记录应满足：睡着 + 清醒 ≤ 卧床 ≤ 首尾跨度。
    func testSleepAggregationInvariantsOnRandomInput() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let base = date(10, 22)
            let segments = (0..<Int.random(in: 1...12, using: &generator)).map { _ -> SleepSegment in
                let start = base.addingTimeInterval(Double.random(in: 0...(9 * 3600), using: &generator))
                let end = start.addingTimeInterval(Double.random(in: 60...(3 * 3600), using: &generator))
                return SleepSegment(start: start, end: end, stage: SleepStage.allCases.randomElement(using: &generator)!)
            }
            for night in SleepAggregator.nights(from: segments, calendar: calendar) {
                XCTAssertLessThanOrEqual(night.asleepDuration + night.awakeDuration, night.inBedDuration + 0.001)
                XCTAssertLessThanOrEqual(night.inBedDuration, night.end.timeIntervalSince(night.start) + 0.001)
                let stageTotal = night.stageDurations.values.reduce(0, +)
                XCTAssertEqual(stageTotal, night.asleepDuration + night.awakeDuration, accuracy: 0.001)
            }
        }
    }
}
