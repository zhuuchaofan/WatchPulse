import XCTest
@testable import WatchPulseShared

final class WorkoutGoalTests: XCTestCase {
    private func calendar(_ identifier: String, firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ string: String, in zone: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: zone)!
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        return formatter.date(from: string)!
    }

    private func workout(
        _ n: Int,
        _ activity: WorkoutActivityKind = .running,
        start: Date,
        minutes: Double = 30,
        distanceKm: Double? = 5,
        location: WorkoutLocation = .outdoor,
        source: WorkoutSourceInfo = Fixture.watch
    ) -> WorkoutRecord {
        WorkoutRecord(
            id: Fixture.uuid(n), activity: activity, location: location,
            startDate: start, endDate: start.addingTimeInterval(minutes * 60), duration: minutes * 60,
            distanceMeters: distanceKm.map { $0 * 1000 }, sourceName: source.name, sourceInfo: source
        )
    }

    private func records(_ workouts: [WorkoutRecord], origin: HealthDataOrigin = .healthKit) -> [WorkoutAnalysisRecord] {
        WorkoutAnalysisBuilder.build(records: workouts, heartRates: [:], origin: origin, zoneSettings: nil).records
    }

    private func goal(_ metric: WorkoutGoalMetric, _ activity: WorkoutActivityKind? = nil, target: Double, paused: Bool = false) throws -> WorkoutGoal {
        try WorkoutGoal(id: Fixture.uuid(500), metric: metric, activity: activity, target: target, isPaused: paused, createdAt: Fixture.base)
    }

    private func current(_ progress: WorkoutGoalProgress) throws -> WorkoutGoalWeekProgress {
        guard case .active(let current, _) = progress else {
            XCTFail("应有进度")
            throw XCTSkip()
        }
        return current
    }

    // MARK: 校验

    func testTargetMustBePositiveAndFinite() {
        for value: Double in [0, -1, .nan, .infinity] {
            XCTAssertThrowsError(try goal(.workoutCount, target: value))
        }
    }

    func testCountMustBeWholeNumber() {
        XCTAssertThrowsError(try goal(.workoutCount, target: 2.5)) { error in
            XCTAssertEqual(error as? WorkoutGoalValidationError, .countNotWholeNumber)
        }
    }

    func testDistanceGoalRejectsActivityWithoutDistance() {
        XCTAssertThrowsError(try goal(.distance, .highIntensityIntervalTraining, target: 10_000)) { error in
            XCTAssertEqual(error as? WorkoutGoalValidationError, .activityHasNoDistance)
        }
        XCTAssertNoThrow(try goal(.distance, nil, target: 10_000))
        XCTAssertNoThrow(try goal(.distance, .cycling, target: 10_000))
    }

    func testObviouslyMistypedTargetIsRejected() {
        XCTAssertThrowsError(try goal(.workoutCount, target: 300))
        XCTAssertThrowsError(try goal(.totalDuration, target: 8 * 86_400))
    }

    func testInputUnitsConvert() {
        XCTAssertEqual(WorkoutGoalMetric.totalDuration.storedValue(fromInput: 150), 9_000)
        XCTAssertEqual(WorkoutGoalMetric.distance.storedValue(fromInput: 42.5), 42_500)
        XCTAssertEqual(WorkoutGoalMetric.distance.inputValue(fromStored: 42_500), 42.5)
        XCTAssertEqual(WorkoutGoalMetric.workoutCount.storedValue(fromInput: 3), 3)
    }

    func testEditingKeepsIdentityAndCreationDate() throws {
        let original = try goal(.workoutCount, target: 3)
        let later = Fixture.base.addingTimeInterval(86_400)
        let edited = try original.updating(metric: .totalDuration, activity: .cycling, target: 7_200, now: later)
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.createdAt, original.createdAt)
        XCTAssertEqual(edited.updatedAt, later)
        XCTAssertEqual(edited.metric, .totalDuration)
        XCTAssertThrowsError(try original.updating(metric: .workoutCount, activity: nil, target: 0, now: later))
    }

    func testPauseKeepsSettings() throws {
        let original = try goal(.distance, .cycling, target: 50_000)
        let paused = original.settingPaused(true, now: Fixture.base.addingTimeInterval(60))
        XCTAssertTrue(paused.isPaused)
        XCTAssertEqual(paused.target, original.target)
        XCTAssertEqual(paused.activity, .cycling)
        XCTAssertFalse(paused.settingPaused(false, now: Fixture.base).isPaused)
    }

    func testCodableRoundTripAndInvalidDataRejected() throws {
        let original = try goal(.distance, .cycling, target: 50_000)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutGoal.self, from: data), original)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["target"] = -5
        let tampered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(WorkoutGoal.self, from: tampered), "不合法的存储数据不能变成目标")
    }

    func testTitlesDoNotJudge() throws {
        XCTAssertEqual(try goal(.workoutCount, target: 3).title, "每周运动 3 次")
        XCTAssertEqual(try goal(.totalDuration, .running, target: 5_400).title, "每周跑步 1小时30分")
        XCTAssertEqual(try goal(.distance, .cycling, target: 50_000).title, "每周骑行距离 50.00 公里")
    }

    // MARK: 进度

    func testCountProgressInCurrentWeek() throws {
        let cal = calendar("UTC")
        let now = date("2026-06-04 12:00:00", in: "UTC") // 周四
        let set = records([
            workout(1, start: date("2026-06-01 07:00:00", in: "UTC")), // 周一
            workout(2, .cycling, start: date("2026-06-03 18:00:00", in: "UTC")),
            workout(3, start: date("2026-05-31 09:00:00", in: "UTC")), // 上周日
        ])
        let week = try current(WorkoutGoalProgressCalculator.progress(for: goal(.workoutCount, target: 3), records: set, now: now, calendar: cal))
        XCTAssertEqual(week.value, 2)
        XCTAssertEqual(week.countedWorkouts, 2)
        XCTAssertTrue(week.isCurrentWeek)
        XCTAssertFalse(week.isAchieved)
        XCTAssertEqual(week.fraction, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(week.week.start, date("2026-06-01 00:00:00", in: "UTC"))
    }

    func testActivityFilterAndDuration() throws {
        let cal = calendar("UTC")
        let now = date("2026-06-04 12:00:00", in: "UTC")
        let set = records([
            workout(1, .running, start: date("2026-06-01 07:00:00", in: "UTC"), minutes: 40),
            workout(2, .cycling, start: date("2026-06-02 07:00:00", in: "UTC"), minutes: 90),
        ])
        let week = try current(WorkoutGoalProgressCalculator.progress(
            for: goal(.totalDuration, .cycling, target: 3_600), records: set, now: now, calendar: cal
        ))
        XCTAssertEqual(week.value, 5_400)
        XCTAssertTrue(week.isAchieved)
        XCTAssertEqual(week.fraction, 1.5, accuracy: 1e-9, "超额如实显示，不截断")
    }

    func testDistanceSkipsMissingDistanceWithoutZeroFill() throws {
        let cal = calendar("UTC")
        let now = date("2026-06-04 12:00:00", in: "UTC")
        let set = records([
            workout(1, .cycling, start: date("2026-06-01 07:00:00", in: "UTC"), distanceKm: 20),
            workout(2, .cycling, start: date("2026-06-02 07:00:00", in: "UTC"), distanceKm: nil, location: .indoor),
            workout(3, .highIntensityIntervalTraining, start: date("2026-06-02 19:00:00", in: "UTC"), distanceKm: nil, location: .indoor),
        ])
        let all = try current(WorkoutGoalProgressCalculator.progress(for: goal(.distance, target: 30_000), records: set, now: now, calendar: cal))
        XCTAssertEqual(all.value, 20_000)
        XCTAssertEqual(all.countedWorkouts, 1)
        XCTAssertEqual(all.workoutsWithoutDistance, 1, "HIIT 本来就没有距离，不算缺失")
    }

    func testSuspectedDuplicateCountedOnceAndReported() throws {
        let cal = calendar("UTC")
        let start = date("2026-06-02 07:00:00", in: "UTC")
        let set = records([
            workout(1, .cycling, start: start, minutes: 60, distanceKm: 20),
            workout(2, .cycling, start: start.addingTimeInterval(40), minutes: 60, distanceKm: 20.4, source: Fixture.thirdParty),
        ])
        let week = try current(WorkoutGoalProgressCalculator.progress(
            for: goal(.distance, .cycling, target: 50_000), records: set, now: start.addingTimeInterval(86_400), calendar: cal
        ))
        XCTAssertEqual(week.countedWorkouts, 1)
        XCTAssertEqual(week.value, 20_000, accuracy: 500)
        XCTAssertEqual(week.suspectedDuplicatesExcluded, 1)
    }

    func testPausedGoalHasNoProgress() throws {
        let progress = WorkoutGoalProgressCalculator.progress(
            for: try goal(.workoutCount, target: 3, paused: true), records: [], now: Fixture.base, calendar: calendar("UTC")
        )
        XCTAssertEqual(progress, .paused)
    }

    func testNoWorkoutsGivesZeroNotMissing() throws {
        let week = try current(WorkoutGoalProgressCalculator.progress(
            for: goal(.workoutCount, target: 2), records: [], now: Fixture.base, calendar: calendar("UTC")
        ))
        XCTAssertEqual(week.value, 0)
        XCTAssertFalse(week.isAchieved)
    }

    func testPreviousWeeksAreConsecutiveAndNonOverlapping() throws {
        let cal = calendar("UTC")
        let now = date("2026-06-04 12:00:00", in: "UTC")
        let set = records([
            workout(1, start: date("2026-05-25 00:00:00", in: "UTC")), // 上周一 0 点，边界
            workout(2, start: date("2026-05-31 23:59:00", in: "UTC")), // 上周日最后一分钟
            workout(3, start: date("2026-05-20 08:00:00", in: "UTC")),
        ])
        guard case .active(let current, let previous) = WorkoutGoalProgressCalculator.progress(
            for: try goal(.workoutCount, target: 2), records: set, now: now, calendar: cal
        ) else { return XCTFail() }
        XCTAssertEqual(previous.count, 3)
        XCTAssertEqual(previous[0].week.end, current.week.start)
        XCTAssertEqual(previous[1].week.end, previous[0].week.start)
        XCTAssertEqual(previous[0].value, 2)
        XCTAssertEqual(previous[1].value, 1)
        XCTAssertEqual(current.value + previous.map(\.value).reduce(0, +), 3, "每条记录只归属一周")
        XCTAssertTrue(previous.allSatisfy { !$0.isCurrentWeek })
    }

    func testWeekBoundaryFollowsCallerTimeZoneAndFirstWeekday() throws {
        // 东京周一 07:00 = UTC 周日 22:00。
        let start = date("2026-06-01 07:00:00", in: "Asia/Tokyo")
        let set = records([workout(1, start: start)])
        let now = date("2026-06-03 12:00:00", in: "Asia/Tokyo")
        let tokyo = try current(WorkoutGoalProgressCalculator.progress(
            for: goal(.workoutCount, target: 1), records: set, now: now, calendar: calendar("Asia/Tokyo")
        ))
        XCTAssertEqual(tokyo.value, 1)
        let utc = try current(WorkoutGoalProgressCalculator.progress(
            for: goal(.workoutCount, target: 1), records: set, now: now, calendar: calendar("UTC")
        ))
        XCTAssertEqual(utc.value, 0, "UTC 日历下这条运动属于上一周")
        let sundayFirst = try current(WorkoutGoalProgressCalculator.progress(
            for: goal(.workoutCount, target: 1), records: set, now: now, calendar: calendar("UTC", firstWeekday: 1)
        ))
        XCTAssertEqual(sundayFirst.value, 1, "以周日为一周第一天时属于本周")
    }

    func testDaylightSavingWeekIsCoveredWithoutGapsOrDuplicates() throws {
        // 2026-03-29 欧洲中部进入夏令时（当天 23 小时）。
        let cal = calendar("Europe/Berlin")
        let now = date("2026-04-01 12:00:00", in: "Europe/Berlin")
        let set = records([
            workout(1, start: date("2026-03-29 01:30:00", in: "Europe/Berlin"), minutes: 60),
            workout(2, start: date("2026-03-29 23:30:00", in: "Europe/Berlin"), minutes: 60),
            workout(3, start: date("2026-03-30 00:30:00", in: "Europe/Berlin"), minutes: 45),
        ])
        guard case .active(let current, let previous) = WorkoutGoalProgressCalculator.progress(
            for: try goal(.totalDuration, target: 3_600), records: set, now: now, calendar: cal
        ) else { return XCTFail() }
        XCTAssertEqual(previous[0].week.end, current.week.start)
        XCTAssertEqual(previous[0].week.duration, 7 * 86_400 - 3_600, "夏令时那一周只有 167 小时")
        XCTAssertEqual(previous[0].value, 7_200, "周日两次运动都属于上周，时长取有效秒数")
        XCTAssertEqual(current.value, 2_700)
    }

    // MARK: 设定前

    private func goal(createdAt: Date, target: Double = 2) throws -> WorkoutGoal {
        try WorkoutGoal(id: Fixture.uuid(501), metric: .workoutCount, activity: nil, target: target, createdAt: createdAt)
    }

    func testWeeksBeforeGoalCreationAreMarkedNotCountedAsMissed() throws {
        // 目标在上上周三设定；本周 = 6/1 周一开始。
        let cal = calendar("UTC")
        let now = date("2026-06-04 12:00:00", in: "UTC")
        let created = date("2026-05-20 15:00:00", in: "UTC")
        let set = records([
            workout(1, start: date("2026-05-12 08:00:00", in: "UTC")), // 设定前的整周（5/11–5/17）
            workout(2, start: date("2026-05-13 08:00:00", in: "UTC")),
        ])
        guard case .active(let current, let previous) = WorkoutGoalProgressCalculator.progress(
            for: try goal(createdAt: created), records: set, now: now, calendar: cal
        ) else { return XCTFail() }
        // previous: 5/25 周、5/18 周（设定当周）、5/11 周（设定前）。
        XCTAssertEqual(previous.map(\.isBeforeGoalCreated), [false, false, true])
        XCTAssertEqual(previous[2].value, 2, "设定前的周仍如实显示数值")
        XCTAssertTrue(previous[2].isAchieved, "数值达到了目标值")
        XCTAssertEqual(previous[2].outcome, .beforeGoalCreated, "但目标还不存在，不算达成也不算未达成")
        XCTAssertEqual(previous[1].outcome, .notAchieved)
        XCTAssertEqual(previous[0].outcome, .notAchieved)
        XCTAssertEqual(current.outcome, .inProgress)
        XCTAssertFalse(current.isBeforeGoalCreated)
        let weeks = previous + [current]
        XCTAssertEqual(weeks.filter(\.countsTowardCompletion).count, 3, "近 N 周只数设定之后（含设定当周）的周")
    }

    func testCreationWeekCountsWorkoutsFromBeforeCreationTime() throws {
        // 周三设定目标；周一、周二已经运动过 → 设定当周按整周计 2 次。
        let cal = calendar("UTC")
        let created = date("2026-06-03 20:00:00", in: "UTC")
        let now = date("2026-06-04 12:00:00", in: "UTC")
        let set = records([
            workout(1, start: date("2026-06-01 07:00:00", in: "UTC")),
            workout(2, start: date("2026-06-02 07:00:00", in: "UTC")),
        ])
        guard case .active(let current, let previous) = WorkoutGoalProgressCalculator.progress(
            for: try goal(createdAt: created), records: set, now: now, calendar: cal
        ) else { return XCTFail() }
        XCTAssertEqual(current.value, 2)
        XCTAssertEqual(current.outcome, .achieved)
        XCTAssertFalse(current.isBeforeGoalCreated)
        XCTAssertTrue(previous.allSatisfy(\.isBeforeGoalCreated), "设定当周之前的三周都是“设定前”")
        XCTAssertTrue(previous.allSatisfy { $0.outcome == .beforeGoalCreated })
    }

    func testGoalCreatedExactlyAtWeekStartMarksOnlyEarlierWeeks() throws {
        let cal = calendar("UTC")
        let created = date("2026-05-25 00:00:00", in: "UTC") // 上周一 0 点整
        let now = date("2026-06-04 12:00:00", in: "UTC")
        guard case .active(_, let previous) = WorkoutGoalProgressCalculator.progress(
            for: try goal(createdAt: created), records: [], now: now, calendar: cal
        ) else { return XCTFail() }
        XCTAssertEqual(previous.map(\.isBeforeGoalCreated), [false, true, true])
        XCTAssertEqual(previous[0].outcome, .notAchieved)
    }

    func testCreationWeekFollowsCallerTimeZone() throws {
        // 东京周一 01:00 设定 = UTC 周日 16:00：东京日历下属于新的一周，UTC 日历下属于上一周。
        let created = date("2026-06-01 01:00:00", in: "Asia/Tokyo")
        let now = date("2026-06-04 12:00:00", in: "Asia/Tokyo")
        guard case .active(_, let tokyo) = WorkoutGoalProgressCalculator.progress(
            for: try goal(createdAt: created), records: [], now: now, calendar: calendar("Asia/Tokyo")
        ), case .active(_, let utc) = WorkoutGoalProgressCalculator.progress(
            for: try goal(createdAt: created), records: [], now: now, calendar: calendar("UTC")
        ) else { return XCTFail() }
        XCTAssertTrue(tokyo[0].isBeforeGoalCreated, "东京：上一周整周在设定之前")
        XCTAssertFalse(utc[0].isBeforeGoalCreated, "UTC：设定时刻落在上一周内，上一周是设定当周")
    }

    func testIncompleteDataIsFlagged() throws {
        let cal = calendar("UTC")
        let now = date("2026-06-04 12:00:00", in: "UTC")
        guard case .active(let current, let previous) = WorkoutGoalProgressCalculator.progress(
            for: try goal(.workoutCount, target: 2), records: [], now: now, calendar: cal,
            dataCoverageStart: date("2026-05-28 00:00:00", in: "UTC")
        ) else { return XCTFail() }
        XCTAssertFalse(current.mayBeIncomplete)
        XCTAssertTrue(previous[0].mayBeIncomplete)
    }

    func testSimulatedDataIsMarked() throws {
        let set = records([workout(1, start: Fixture.base)], origin: .simulated)
        let week = try current(WorkoutGoalProgressCalculator.progress(
            for: goal(.workoutCount, target: 1), records: set, now: Fixture.base.addingTimeInterval(3_600), calendar: calendar("UTC")
        ))
        XCTAssertTrue(week.containsSimulatedData)
    }
}
