import Foundation
import XCTest
@testable import WatchPulseCore
import WatchPulseShared

final class ProgressSummaryTests: XCTestCase {
    /// 2026-06-04 12:00 UTC（周四）；每周从周一开始。
    private let now = Date(timeIntervalSince1970: 1_780_574_400)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func workout(_ n: Int, daysAgo: Double, activity: WorkoutActivityKind = .cycling) -> WorkoutRecord {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return WorkoutRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
            activity: activity, location: .outdoor,
            startDate: start, endDate: start.addingTimeInterval(1_800), duration: 1_800,
            distanceMeters: 10_000, sourceName: "体能训练"
        )
    }

    private func set(_ workouts: [WorkoutRecord], origin: HealthDataOrigin = .healthKit) -> WorkoutAnalysisSet {
        WorkoutAnalysisBuilder.build(records: workouts, heartRates: [:], origin: origin, zoneSettings: nil)
    }

    func testBucketsRecordsIntoFourWeeksOldestFirst() {
        // 本周：6/2、6/3；上周（5/25 起）：5/28；再上周：无；最早一周（5/11 起）：5/15。
        let summary = ProgressSummary.make(
            from: set([workout(1, daysAgo: 1), workout(2, daysAgo: 2), workout(3, daysAgo: 7), workout(4, daysAgo: 20)]),
            readLimit: 200, now: now, calendar: calendar
        )
        XCTAssertEqual(summary.weeks.map(\.workoutCount), [1, 0, 1, 2])
        XCTAssertEqual(summary.weeks.map(\.isCurrentWeek), [false, false, false, true])
        XCTAssertEqual(summary.weeks.last?.label, "本周")
        XCTAssertEqual(summary.totalWorkouts, 4)
        XCTAssertEqual(summary.activeWeekCount, 3)
        XCTAssertTrue(summary.hasEnoughWeeksForTrend)
        XCTAssertEqual(summary.headline, "最近 4 周运动 4 次")
        XCTAssertFalse(summary.mayBeIncomplete)
    }

    func testOnlyOneActiveWeekDoesNotClaimATrend() {
        let summary = ProgressSummary.make(from: set([workout(1, daysAgo: 1)]), readLimit: 200, now: now, calendar: calendar)
        XCTAssertFalse(summary.hasEnoughWeeksForTrend)
        XCTAssertTrue(summary.detail.contains("再多记录几周"))
    }

    func testNoRecordsInRangeIsExplicit() {
        let summary = ProgressSummary.make(from: set([workout(1, daysAgo: 90)]), readLimit: 200, now: now, calendar: calendar)
        XCTAssertFalse(summary.hasAnyWorkout)
        XCTAssertEqual(summary.headline, "最近 4 周还没有运动记录")
        XCTAssertEqual(summary.weeks.count, ProgressSummary.weekCount)
        XCTAssertNotNil(summary.latestWorkout, "更早的运动仍可作为最近一次")
    }

    func testEmptySetHasNoLatestWorkout() {
        let summary = ProgressSummary.make(from: set([]), readLimit: 200, now: now, calendar: calendar)
        XCTAssertNil(summary.latestWorkout)
        XCTAssertEqual(summary.weeks.map(\.workoutCount), [0, 0, 0, 0])
    }

    func testLatestWorkoutIsMostRecentStart() {
        let summary = ProgressSummary.make(
            from: set([workout(1, daysAgo: 1), workout(2, daysAgo: 3)]),
            readLimit: 200, now: now, calendar: calendar
        )
        XCTAssertEqual(summary.latestWorkout?.id, workout(1, daysAgo: 1).id)
    }

    func testBriefHeadlineForFewComparableWorkoutsHasNoConclusion() {
        let records = set([workout(1, daysAgo: 1), workout(2, daysAgo: 3)]).records
        guard let latest = records.first else { return XCTFail("应有最近一次运动") }
        let feedback = WorkoutFeedbackCalculator.feedback(for: latest, among: records)
        if case .compared = feedback.status { XCTFail("可比运动不足时不下比较结论") }
        XCTAssertFalse(WorkoutFeedbackPresentation.briefHeadline(feedback).contains("样本"))
    }

    func testReadLimitReachedMarksOlderWeeksPossiblyIncomplete() {
        let workouts = [workout(1, daysAgo: 1), workout(2, daysAgo: 7), workout(3, daysAgo: 20)]
        let summary = ProgressSummary.make(from: set(workouts), readLimit: 3, now: now, calendar: calendar)
        XCTAssertTrue(summary.mayBeIncomplete)
    }

    func testSimulatedOriginIsCarried() {
        let summary = ProgressSummary.make(from: set([workout(1, daysAgo: 1)], origin: .simulated), readLimit: 200, now: now, calendar: calendar)
        XCTAssertTrue(summary.containsSimulatedData)
    }

    func testChartDescriptionListsEveryWeek() {
        let summary = ProgressSummary.make(from: set([workout(1, daysAgo: 1)]), readLimit: 200, now: now, calendar: calendar)
        XCTAssertTrue(summary.chartDescription.contains("本周 1 次"))
        XCTAssertEqual(summary.chartDescription.components(separatedBy: " 次").count - 1, 4, "四周各出现一次")
    }
}
