import Foundation
import XCTest
@testable import WatchPulseCore
import WatchPulseShared

@MainActor
final class WorkoutGoalsViewModelTests: XCTestCase {
    /// 2026-06-04 12:00 UTC（周四）。
    private let now = Date(timeIntervalSince1970: 1_780_574_400)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func workout(_ n: Int, hoursAgo: Double, activity: WorkoutActivityKind = .cycling, distanceKm: Double? = 10) -> WorkoutRecord {
        let start = now.addingTimeInterval(-hoursAgo * 3_600)
        return WorkoutRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
            activity: activity, location: .outdoor,
            startDate: start, endDate: start.addingTimeInterval(1_800), duration: 1_800,
            distanceMeters: distanceKm.map { $0 * 1000 }, sourceName: "体能训练"
        )
    }

    private func makeViewModel(
        store: any WorkoutGoalStore = InMemoryWorkoutGoalStore(),
        service: MockWorkoutHistoryService,
        fetchLimit: Int = 200
    ) -> WorkoutGoalsViewModel {
        let fixed = now
        return WorkoutGoalsViewModel(store: store, service: service, calendar: calendar, fetchLimit: fetchLimit, now: { fixed })
    }

    private func currentWeek(_ item: WorkoutGoalItem?) -> WorkoutGoalWeekProgress? {
        guard case .active(let current, _)? = item?.progress else { return nil }
        return current
    }

    func testAddComputesProgressFromHealthRecords() async {
        let service = MockWorkoutHistoryService(workouts: .value([workout(1, hoursAgo: 24), workout(2, hoursAgo: 48, distanceKm: 25)]))
        let viewModel = makeViewModel(service: service)
        await viewModel.load()

        XCTAssertTrue(viewModel.add(metric: .distance, activity: .cycling, input: 50))
        XCTAssertEqual(viewModel.goals.count, 1)
        XCTAssertEqual(viewModel.goals[0].target, 50_000)
        let week = currentWeek(viewModel.items.first)
        XCTAssertEqual(week?.value, 35_000)
        XCTAssertEqual(week?.countedWorkouts, 2)
        XCTAssertEqual(service.heartRateFetchCount, 0, "目标不需要读取心率曲线")
    }

    func testInvalidInputIsRejectedAndReported() async {
        let viewModel = makeViewModel(service: MockWorkoutHistoryService())
        XCTAssertFalse(viewModel.add(metric: .workoutCount, activity: nil, input: 0))
        XCTAssertEqual(viewModel.lastError, .targetNotPositive)
        XCTAssertFalse(viewModel.add(metric: .distance, activity: .highIntensityIntervalTraining, input: 5))
        XCTAssertEqual(viewModel.lastError, .activityHasNoDistance)
        XCTAssertTrue(viewModel.goals.isEmpty)
        XCTAssertTrue(viewModel.add(metric: .workoutCount, activity: nil, input: 3))
        XCTAssertNil(viewModel.lastError)
    }

    func testEditPauseAndDelete() async {
        let store = InMemoryWorkoutGoalStore()
        let viewModel = makeViewModel(store: store, service: MockWorkoutHistoryService(workouts: .value([workout(1, hoursAgo: 2)])))
        await viewModel.load()
        viewModel.add(metric: .workoutCount, activity: nil, input: 3)
        let goal = viewModel.goals[0]

        XCTAssertTrue(viewModel.update(goal, metric: .totalDuration, activity: nil, input: 90))
        XCTAssertEqual(viewModel.goals[0].id, goal.id)
        XCTAssertEqual(viewModel.goals[0].target, 5_400)

        viewModel.setPaused(true, for: viewModel.goals[0])
        XCTAssertEqual(viewModel.items[0].progress, .paused)
        viewModel.setPaused(false, for: viewModel.goals[0])
        XCTAssertEqual(currentWeek(viewModel.items[0])?.value, 1_800)

        viewModel.delete(viewModel.goals[0])
        XCTAssertTrue(viewModel.goals.isEmpty)
        XCTAssertTrue(store.allGoals().isEmpty)
    }

    func testGoalsStayManageableWhenRecordsFail() async {
        let service = MockWorkoutHistoryService(workouts: .failure(.protectedDataUnavailable))
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        XCTAssertEqual(viewModel.records, .failed(.protectedDataUnavailable))
        XCTAssertTrue(viewModel.add(metric: .workoutCount, activity: nil, input: 2))
        XCTAssertNil(viewModel.items[0].progress, "读取失败时不显示 0，而是没有进度")
    }

    func testNoWorkoutsStillShowsZeroProgress() async {
        let viewModel = makeViewModel(service: MockWorkoutHistoryService())
        await viewModel.load()
        viewModel.add(metric: .workoutCount, activity: nil, input: 2)
        XCTAssertEqual(currentWeek(viewModel.items[0])?.value, 0)
    }

    func testReachingFetchLimitFlagsOlderWeeks() async {
        // 最早一条在上周日：本周完整，之前几周可能缺记录。
        let workouts = [1.0, 60, 100].enumerated().map { workout($0.offset + 1, hoursAgo: $0.element) }
        let viewModel = makeViewModel(service: MockWorkoutHistoryService(workouts: .value(workouts)), fetchLimit: 3)
        await viewModel.load()
        viewModel.add(metric: .workoutCount, activity: nil, input: 2)
        guard case .active(let current, let previous)? = viewModel.items[0].progress else { return XCTFail() }
        XCTAssertFalse(current.mayBeIncomplete)
        XCTAssertTrue(previous.allSatisfy(\.mayBeIncomplete), "更早的周可能缺记录")
    }

    func testReloadPicksUpNewWorkoutsWithoutClearingProgress() async {
        let service = MockWorkoutHistoryService(workouts: .value([workout(1, hoursAgo: 24)]))
        let viewModel = makeViewModel(service: service)
        await viewModel.load()
        viewModel.add(metric: .workoutCount, activity: nil, input: 3)
        XCTAssertEqual(currentWeek(viewModel.items[0])?.value, 1)

        service.insert(workout(2, hoursAgo: 1), heartRates: [])
        await viewModel.load()
        XCTAssertEqual(currentWeek(viewModel.items[0])?.value, 2, "新完成的运动计入本周进度")
    }

    func testUnavailableHealthData() async {
        let viewModel = makeViewModel(service: MockWorkoutHistoryService(isHealthDataAvailable: false))
        await viewModel.load()
        XCTAssertEqual(viewModel.records, .healthDataUnavailable)
    }

    // MARK: 存储

    func testUserDefaultsStorePersistsAcrossInstances() throws {
        let suite = "WorkoutGoalStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = UserDefaultsWorkoutGoalStore(defaults: defaults)
        let goal = try WorkoutGoal(id: UUID(), metric: .workoutCount, activity: nil, target: 3, createdAt: now)
        first.save(goal)
        first.save(goal.settingPaused(true, now: now))

        let second = UserDefaultsWorkoutGoalStore(defaults: defaults)
        XCTAssertEqual(second.allGoals().count, 1)
        XCTAssertTrue(second.allGoals()[0].isPaused)
        XCTAssertFalse(second.recoveredFromUnreadableData)

        second.delete(id: goal.id)
        XCTAssertTrue(UserDefaultsWorkoutGoalStore(defaults: defaults).allGoals().isEmpty)
    }

    func testUnreadableStoredDataIsBackedUpNotSilentlyLost() throws {
        let suite = "WorkoutGoalStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let garbage = Data("not json".utf8)
        defaults.set(garbage, forKey: UserDefaultsWorkoutGoalStore.goalsKey)

        let store = UserDefaultsWorkoutGoalStore(defaults: defaults)
        XCTAssertTrue(store.recoveredFromUnreadableData)
        XCTAssertTrue(store.allGoals().isEmpty)
        XCTAssertEqual(defaults.data(forKey: UserDefaultsWorkoutGoalStore.unreadableBackupKey), garbage)
    }
}
