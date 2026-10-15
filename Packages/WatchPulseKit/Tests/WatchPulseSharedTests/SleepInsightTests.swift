import Foundation
import XCTest
import WatchPulseShared

final class SleepInsightTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 3) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func night(wakeDay: Int, bed: (Int, Int), wake: (Int, Int), stages: Bool = true, source: String = "Watch") -> [SleepSegment] {
        let start = bed.0 >= 18 ? date(wakeDay - 1, bed.0, bed.1) : date(wakeDay, bed.0, bed.1)
        let end = date(wakeDay, wake.0, wake.1)
        guard stages else {
            return [SleepSegment(start: start, end: end, stage: .inBed, sourceName: "iPhone")]
        }
        let mid = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        return [
            SleepSegment(start: start, end: end, stage: .inBed, sourceName: "iPhone"),
            SleepSegment(start: start, end: mid, stage: .core, sourceName: source),
            SleepSegment(start: mid, end: mid.addingTimeInterval(3_600), stage: .deep, sourceName: source),
            SleepSegment(start: mid.addingTimeInterval(3_600), end: mid.addingTimeInterval(4_200), stage: .awake, sourceName: source),
            SleepSegment(start: mid.addingTimeInterval(4_200), end: end, stage: .rem, sourceName: source),
        ]
    }

    func testLatestNightStagesAndShares() throws {
        let nights = SleepAggregator.nights(from: night(wakeDay: 10, bed: (23, 0), wake: (7, 0)), calendar: calendar)
        let insight = SleepInsight(nights: nights, now: date(10, 12), calendar: calendar)
        XCTAssertEqual(insight.latestNight?.date, date(10, 0))
        XCTAssertTrue(insight.hasStages)
        XCTAssertFalse(insight.isInBedOnly)
        XCTAssertEqual(insight.stages.map(\.stage), [.deep, .rem, .core, .awake])
        XCTAssertEqual(insight.stages.map(\.fraction).reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(insight.stages.first { $0.stage == .deep }).duration, 3_600)
        XCTAssertNil(insight.regularity, "1 晚不足以计算规律性")
    }

    func testInBedOnlyIsFlagged() {
        let nights = SleepAggregator.nights(from: night(wakeDay: 10, bed: (23, 0), wake: (7, 0), stages: false), calendar: calendar)
        let insight = SleepInsight(nights: nights, now: date(10, 12), calendar: calendar)
        XCTAssertTrue(insight.isInBedOnly)
        XCTAssertFalse(insight.hasStages)
        XCTAssertTrue(insight.stages.isEmpty)
    }

    func testRegularityAcrossMidnight() throws {
        // 入睡 23:30 / 00:30 / 23:30 / 00:30，醒来 07:00 / 08:00 / 07:00 / 08:00。
        var segments: [SleepSegment] = []
        segments += night(wakeDay: 10, bed: (23, 30), wake: (7, 0))
        segments += night(wakeDay: 11, bed: (0, 30), wake: (8, 0))
        segments += night(wakeDay: 12, bed: (23, 30), wake: (7, 0))
        segments += night(wakeDay: 13, bed: (0, 30), wake: (8, 0))
        let nights = SleepAggregator.nights(from: segments, calendar: calendar)
        let regularity = try XCTUnwrap(SleepInsight(nights: nights, now: date(13, 12), calendar: calendar).regularity)
        XCTAssertEqual(regularity.nightCount, 4)
        XCTAssertEqual(regularity.averageBedtimeMinutes, 0, accuracy: 0.01, "跨午夜的平均入睡时刻应为 00:00，而不是中午")
        XCTAssertEqual(regularity.bedtimeDeviationMinutes, 30, accuracy: 0.01)
        XCTAssertEqual(regularity.averageWakeMinutes, 450, accuracy: 0.01)
        XCTAssertEqual(regularity.wakeDeviationMinutes, 30, accuracy: 0.01)
        XCTAssertEqual(MetricFormatting.clockTime(minutesFromMidnight: regularity.averageBedtimeMinutes), "00:00")
        XCTAssertEqual(MetricFormatting.clockTime(minutesFromMidnight: -20), "23:40")
        XCTAssertEqual(MetricFormatting.clockTime(minutesFromMidnight: 425), "07:05")
    }

    func testSplitNightAndMultipleSourcesUsePrimarySource() throws {
        // 一晚被拆成两段（中途起夜），第三方 App 的“睡眠”不覆盖 Watch 的清醒。
        var segments = night(wakeDay: 10, bed: (23, 0), wake: (3, 0))
        segments += night(wakeDay: 10, bed: (3, 30), wake: (7, 0))
        segments.append(SleepSegment(start: date(9, 23), end: date(10, 7), stage: .asleepUnspecified, sourceName: "App"))
        let nights = SleepAggregator.nights(from: segments, calendar: calendar)
        XCTAssertEqual(nights.count, 1)
        let insight = SleepInsight(nights: nights, now: date(10, 12), calendar: calendar)
        XCTAssertEqual(insight.latestNight?.primarySourceName, "Watch")
        XCTAssertNil(insight.stages.first { $0.stage == .asleepUnspecified }, "主来源有分期时不混入第三方未分期睡眠")
    }

    func testFutureNightsAndEmpty() {
        let nights = SleepAggregator.nights(from: night(wakeDay: 20, bed: (23, 0), wake: (7, 0)), calendar: calendar)
        let insight = SleepInsight(nights: nights, now: date(10, 12), calendar: calendar)
        XCTAssertNil(insight.latestNight)
        XCTAssertEqual(insight.nightCount, 0)
        XCTAssertNil(SleepInsight(nights: [], now: date(10, 12), calendar: calendar).latestNight)
    }

    func testRegularityAcrossDaylightSaving() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        func at(_ day: Int, _ hour: Int) -> Date { berlin.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour))! }
        // 2026-03-29 夏令时开始：墙上时间每晚都是 23:00 入睡、07:00 醒来。
        let segments = (27...31).flatMap { wakeDay in
            [SleepSegment(start: at(wakeDay - 1, 23), end: at(wakeDay, 7), stage: .core, sourceName: "Watch")]
        }
        let nights = SleepAggregator.nights(from: segments, calendar: berlin)
        let regularity = try XCTUnwrap(SleepInsight(nights: nights, now: at(31, 12), calendar: berlin).regularity)
        XCTAssertEqual(regularity.bedtimeDeviationMinutes, 0, accuracy: 0.01, "夏令时切换不应造成 1 小时的入睡时刻偏差")
        XCTAssertEqual(regularity.averageBedtimeMinutes, -60, accuracy: 0.01)
    }
}
