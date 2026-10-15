import Foundation
import XCTest
@testable import WatchPulseCore
import WatchPulseShared

@MainActor
final class WorkoutHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func workout(id: Int = 1, start: Date, minutes: Double = 30) -> WorkoutRecord {
        WorkoutRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            activity: .running,
            location: .outdoor,
            startDate: start,
            endDate: start.addingTimeInterval(minutes * 60),
            duration: minutes * 60,
            sourceName: "test"
        )
    }

    func testHistoryLoadsNewestFirst() async {
        let older = workout(id: 1, start: now.addingTimeInterval(-86_400))
        let newer = workout(id: 2, start: now)
        let service = MockWorkoutHistoryService(workouts: .value([older, newer]))
        let viewModel = WorkoutHistoryViewModel(service: service)

        await viewModel.load()

        XCTAssertEqual(viewModel.state.value?.map(\.id), [newer.id, older.id])
        XCTAssertEqual(viewModel.dataOrigin, .simulated)
    }

    func testHistoryRespectsLimit() async {
        let service = MockWorkoutHistoryService.demo(now: now, count: 20)
        let viewModel = WorkoutHistoryViewModel(service: service, limit: 5)
        await viewModel.load()
        XCTAssertEqual(viewModel.state.value?.count, 5)
    }

    func testHistoryEmptyFailureAndUnavailable() async {
        let empty = WorkoutHistoryViewModel(service: MockWorkoutHistoryService())
        await empty.load()
        XCTAssertEqual(empty.state, .noData)

        let failing = WorkoutHistoryViewModel(service: MockWorkoutHistoryService(workouts: .failure(.protectedDataUnavailable)))
        await failing.load()
        XCTAssertEqual(failing.state, .failed(.protectedDataUnavailable))

        let unavailable = WorkoutHistoryViewModel(service: MockWorkoutHistoryService(isHealthDataAvailable: false))
        await unavailable.load()
        XCTAssertEqual(unavailable.state, .healthDataUnavailable)
    }

    func testRefreshKeepsExistingListWhileReloading() async {
        let service = MockWorkoutHistoryService(workouts: .value([workout(start: now)]))
        let viewModel = WorkoutHistoryViewModel(service: service)
        await viewModel.load()

        let added = workout(id: 9, start: now.addingTimeInterval(600))
        service.insert(added, heartRates: [])
        await viewModel.load()

        XCTAssertEqual(viewModel.state.value?.first?.id, added.id)
        XCTAssertEqual(service.workoutFetchCount, 2)
    }

    func testGroupedByMonth() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let march = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        let marchLater = calendar.date(from: DateComponents(year: 2026, month: 3, day: 20))!
        let april = calendar.date(from: DateComponents(year: 2026, month: 4, day: 2))!
        let groups = WorkoutHistoryViewModel.groupedByMonth(
            [workout(id: 1, start: march), workout(id: 2, start: april), workout(id: 3, start: marchLater)],
            calendar: calendar
        )
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].month, calendar.date(from: DateComponents(year: 2026, month: 4, day: 1)))
        XCTAssertEqual(groups[1].workouts.map(\.startDate), [marchLater, march])
    }

    func testDetailLoadsHeartRateCurveWithinWorkout() async {
        let target = workout(id: 1, start: now, minutes: 60)
        let other = workout(id: 2, start: now.addingTimeInterval(-7_200), minutes: 30)
        let inside = (0..<1_000).map { HeartRatePoint(date: now.addingTimeInterval(Double($0) * 3), beatsPerMinute: 100 + Double($0 % 60)) }
        let outside = [HeartRatePoint(date: now.addingTimeInterval(-7_000), beatsPerMinute: 200)]
        let service = MockWorkoutHistoryService(
            workouts: .value([target, other]),
            heartRates: [target.id: .value(inside), other.id: .value(outside)]
        )
        let viewModel = WorkoutDetailViewModel(workout: target, service: service, maxChartPoints: 200)

        await viewModel.load()

        let detail = viewModel.state.value
        XCTAssertEqual(detail?.sampleCount, 1_000)
        XCTAssertLessThanOrEqual(detail?.points.count ?? 0, 200)
        XCTAssertEqual(detail?.statistics.maximum, 159)
        XCTAssertEqual(detail?.statistics.minimum, 100)
        let zoneTotal = detail?.zoneDurations.values.reduce(0, +) ?? 0
        XCTAssertEqual(zoneTotal, 999 * 3, accuracy: 0.001)
    }

    func testDetailNoDataAndFailure() async {
        let target = workout(start: now)
        let empty = WorkoutDetailViewModel(workout: target, service: MockWorkoutHistoryService())
        await empty.load()
        XCTAssertEqual(empty.state, .noData)

        let failing = WorkoutDetailViewModel(
            workout: target,
            service: MockWorkoutHistoryService(heartRates: [target.id: .failure(.queryFailed(reason: "x"))])
        )
        await failing.load()
        XCTAssertEqual(failing.state, .failed(.queryFailed(reason: "x")))
    }

    func testHeartRateZones() async {
        let start = now
        let points = [
            HeartRatePoint(date: start, beatsPerMinute: 100),                       // 50% → 热身
            HeartRatePoint(date: start.addingTimeInterval(10), beatsPerMinute: 130), // 65% → 燃脂
            HeartRatePoint(date: start.addingTimeInterval(20), beatsPerMinute: 150), // 75% → 有氧
            HeartRatePoint(date: start.addingTimeInterval(30), beatsPerMinute: 170), // 85% → 无氧
            HeartRatePoint(date: start.addingTimeInterval(40), beatsPerMinute: 200), // 100% → 极限
            HeartRatePoint(date: start.addingTimeInterval(500), beatsPerMinute: 120), // 前面的间隔 460 秒视为缺测
        ]
        let zones = HeartRateZone.durations(for: points)
        XCTAssertEqual(zones[.warmUp], 10)
        XCTAssertEqual(zones[.fatBurn], 10)
        XCTAssertEqual(zones[.aerobic], 10)
        XCTAssertEqual(zones[.anaerobic], 10)
        XCTAssertNil(zones[.maximum])
        XCTAssertTrue(HeartRateZone.durations(for: []).isEmpty)
    }

    func testDemoHistoryIsDeterministicAndLabelled() async {
        let first = SimulatedWorkoutHistory.workouts(endingBefore: now, count: 6)
        let second = SimulatedWorkoutHistory.workouts(endingBefore: now, count: 6)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.sourceName == SimulatedWorkoutHistory.sourceName })
        XCTAssertTrue(first.allSatisfy { $0.endDate < now })
        for workout in first {
            let series = SimulatedWorkoutHistory.heartRates(for: workout)
            XCTAssertFalse(series.isEmpty)
            XCTAssertTrue(series.allSatisfy { $0.date >= workout.startDate && $0.date <= workout.endDate })
        }
    }
}
