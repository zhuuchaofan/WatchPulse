import XCTest
@testable import WatchPulseShared

final class WorkoutVolumeSummaryTests: XCTestCase {
    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ string: String, in zone: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: zone)!
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        return formatter.date(from: string)!
    }

    private func workout(_ n: Int, start: Date, minutes: Double = 45, distanceKm: Double? = 10, source: WorkoutSourceInfo = Fixture.watch) -> WorkoutRecord {
        WorkoutRecord(
            id: Fixture.uuid(n), activity: .running, location: .outdoor,
            startDate: start, endDate: start.addingTimeInterval(minutes * 60), duration: minutes * 60,
            distanceMeters: distanceKm.map { $0 * 1000 }, sourceName: source.name, sourceInfo: source
        )
    }

    private func records(_ workouts: [WorkoutRecord], origin: HealthDataOrigin = .healthKit) -> [WorkoutAnalysisRecord] {
        WorkoutAnalysisBuilder.build(records: workouts, heartRates: [:], origin: origin, zoneSettings: nil).records
    }

    func testTotalsCountOnlyEligibleRecordsAndReportUncertainty() {
        let ride = Fixture.workout(1)
        let suspected = Fixture.workout(2, start: 40, source: Fixture.thirdParty)
        let other = Fixture.workout(3, start: 86_400, distanceKm: nil)
        let analysisRecords = records([ride, suspected, other])
        let interval = DateInterval(start: Fixture.base.addingTimeInterval(-3_600), duration: 3 * 86_400)
        let summary = WorkoutVolumeSummary.summarize(analysisRecords, interval: interval, calendar: calendar("UTC"))
        XCTAssertEqual(summary.workoutCount, 2, "疑似重复只计一次")
        XCTAssertEqual(summary.suspectedExcludedCount, 1)
        XCTAssertEqual(summary.totalDuration, 2 * 3_600, accuracy: 0.001)
        XCTAssertEqual(summary.totalDistanceMeters, 20_000, accuracy: 0.001, "缺失距离不补 0，也不拉低合计")
        XCTAssertEqual(summary.distanceWorkoutCount, 1)
        XCTAssertTrue(summary.hasSuspectedDuplicates)
    }

    func testSimulatedDataIsFlagged() {
        let set = records([Fixture.workout(1)], origin: .simulated)
        let summary = WorkoutVolumeSummary.summarize(set, interval: DateInterval(start: .distantPast, end: .distantFuture), calendar: calendar("UTC"))
        XCTAssertTrue(summary.containsSimulatedData)
    }

    func testWorkoutIsAttributedToLocalDayOfItsStart() {
        // 23:30 开始、跨午夜：归属开始那天。
        let late = workout(1, start: date("2026-06-10 23:30:00", in: "Asia/Tokyo"), minutes: 60)
        let summary = WorkoutVolumeSummary.summarize(
            records([late]), interval: DateInterval(start: .distantPast, end: .distantFuture), calendar: calendar("Asia/Tokyo")
        )
        XCTAssertEqual(summary.dailyBuckets.count, 1)
        XCTAssertEqual(summary.dailyBuckets[0].dayStart, date("2026-06-10 00:00:00", in: "Asia/Tokyo"))
    }

    func testSameInstantFallsOnDifferentDaysInDifferentTimeZones() {
        let start = date("2026-06-10 23:30:00", in: "Asia/Tokyo") // = 06-10 07:30 洛杉矶
        let all = records([workout(1, start: start)])
        let interval = DateInterval(start: .distantPast, end: .distantFuture)
        let tokyo = WorkoutVolumeSummary.summarize(all, interval: interval, calendar: calendar("Asia/Tokyo"))
        let utc = WorkoutVolumeSummary.summarize(all, interval: interval, calendar: calendar("UTC"))
        let la = WorkoutVolumeSummary.summarize(all, interval: interval, calendar: calendar("America/Los_Angeles"))
        XCTAssertEqual(tokyo.dailyBuckets[0].dayStart, date("2026-06-10 00:00:00", in: "Asia/Tokyo"))
        XCTAssertEqual(utc.dailyBuckets[0].dayStart, date("2026-06-10 00:00:00", in: "UTC"))
        XCTAssertEqual(la.dailyBuckets[0].dayStart, date("2026-06-10 00:00:00", in: "America/Los_Angeles"))
        XCTAssertEqual(tokyo.totalDuration, la.totalDuration, "总量与时区无关")
    }

    func testDaylightSavingSpringForwardNoDayLostOrDuplicated() {
        // 2026-03-08 美国夏令时开始（该日 23 小时）：连续 7 天每天一次，每天落在各自日历日。
        let cal = calendar("America/New_York")
        let monday = date("2026-03-02 07:00:00", in: "America/New_York")
        let workouts = (0..<7).map { index in
            workout(index + 1, start: cal.date(byAdding: .day, value: index, to: monday)!)
        }
        let week = cal.dateInterval(of: .weekOfYear, for: monday)!
        let summary = WorkoutVolumeSummary.summarize(records(workouts), interval: week, calendar: cal)
        XCTAssertEqual(summary.workoutCount, 7)
        XCTAssertEqual(summary.dailyBuckets.count, 7)
        XCTAssertEqual(Set(summary.dailyBuckets.map(\.dayStart)).count, 7)
        XCTAssertTrue(summary.dailyBuckets.allSatisfy { $0.workoutCount == 1 })
        XCTAssertEqual(week.duration, 7 * 86_400 - 3_600, accuracy: 0.1, "夏令时那周只有 167 小时")
    }

    func testDurationAcrossDaylightSavingUsesActiveSecondsNotWallClock() {
        // 02:30 本地时间不存在；从 01:30 EST 跑到 03:30 EDT 实际只过了 1 小时。
        let cal = calendar("America/New_York")
        let start = date("2026-03-08 01:30:00", in: "America/New_York")
        let run = WorkoutRecord(
            id: Fixture.uuid(1), activity: .running, location: .outdoor,
            startDate: start, endDate: start.addingTimeInterval(3_600), duration: 3_600, sourceName: "X"
        )
        let summary = WorkoutVolumeSummary.summarize(records([run]), interval: cal.dateInterval(of: .day, for: start)!, calendar: cal)
        XCTAssertEqual(summary.totalDuration, 3_600)
        XCTAssertEqual(cal.component(.hour, from: run.endDate), 3, "墙上时间跳过 02 点，不能用墙上时间相减")
    }

    func testDaylightSavingFallBackTwoWorkoutsInRepeatedHourBothCounted() {
        // 2026-11-01 01:30 出现两次（EDT 与 EST）。
        let cal = calendar("America/New_York")
        let first = Date(timeIntervalSince1970: 1_793_511_000)  // 2026-11-01 01:30 EDT
        let second = first.addingTimeInterval(3_600)            // 01:30 EST
        let summary = WorkoutVolumeSummary.summarize(
            records([workout(1, start: first, minutes: 20), workout(2, start: second, minutes: 20, source: Fixture.thirdParty)]),
            interval: cal.dateInterval(of: .day, for: first)!, calendar: cal
        )
        XCTAssertEqual(cal.component(.hour, from: first), cal.component(.hour, from: second))
        XCTAssertEqual(summary.workoutCount, 2, "不同绝对时刻，不能因墙上时间相同而去重")
        XCTAssertEqual(summary.dailyBuckets.count, 1)
    }

    func testIntervalFiltersByStartInstant() {
        let cal = calendar("UTC")
        let a = workout(1, start: date("2026-06-01 10:00:00", in: "UTC"))
        let b = workout(2, start: date("2026-06-08 10:00:00", in: "UTC"))
        let week = DateInterval(start: date("2026-06-01 00:00:00", in: "UTC"), end: date("2026-06-08 00:00:00", in: "UTC"))
        XCTAssertEqual(WorkoutVolumeSummary.summarize(records([a, b]), interval: week, calendar: cal).workoutCount, 1)
    }

    func testWorkoutStartingExactlyAtBoundaryBelongsToLaterIntervalOnly() {
        let cal = calendar("UTC")
        let boundary = date("2026-06-08 00:00:00", in: "UTC")
        let set = records([workout(1, start: boundary)])
        let previous = DateInterval(start: date("2026-06-01 00:00:00", in: "UTC"), end: boundary)
        let next = DateInterval(start: boundary, end: date("2026-06-15 00:00:00", in: "UTC"))
        XCTAssertEqual(WorkoutVolumeSummary.summarize(set, interval: previous, calendar: cal).workoutCount, 0)
        XCTAssertEqual(WorkoutVolumeSummary.summarize(set, interval: next, calendar: cal).workoutCount, 1)
    }

    func testEmptySummary() {
        let summary = WorkoutVolumeSummary.summarize([], interval: DateInterval(start: .distantPast, end: .distantFuture), calendar: calendar("UTC"))
        XCTAssertEqual(summary.workoutCount, 0)
        XCTAssertNil(summary.averageSpeedMetersPerSecond)
        XCTAssertTrue(summary.dailyBuckets.isEmpty)
    }
}
