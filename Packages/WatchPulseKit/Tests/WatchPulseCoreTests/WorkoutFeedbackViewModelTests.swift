import Foundation
import XCTest
@testable import WatchPulseCore
import WatchPulseShared

@MainActor
final class WorkoutFeedbackViewModelTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_780_574_400)
    private let day: TimeInterval = 86_400

    private func ride(_ n: Int, daysAfterBase: Double, activity: WorkoutActivityKind = .cycling, distanceKm: Double = 20) -> WorkoutRecord {
        let start = base.addingTimeInterval(daysAfterBase * day)
        return WorkoutRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
            activity: activity, location: .outdoor,
            startDate: start, endDate: start.addingTimeInterval(3_600), duration: 3_600,
            distanceMeters: distanceKm * 1000, averageHeartRate: 140, sourceName: "体能训练"
        )
    }

    private func heartRates(_ workouts: [WorkoutRecord]) -> [UUID: MockHealthDataService.Behavior<[HeartRatePoint]>] {
        Dictionary(uniqueKeysWithValues: workouts.map { workout in
            (workout.id, .value(stride(from: 0.0, through: 3_600, by: 5).map {
                HeartRatePoint(date: workout.startDate.addingTimeInterval($0), beatsPerMinute: 140)
            }))
        })
    }

    func testLoadsFeedbackForTheOpenedWorkout() async {
        let workouts = [ride(10, daysAfterBase: 10, distanceKm: 22)] + (1...4).map { ride($0, daysAfterBase: Double($0)) }
        let service = MockWorkoutHistoryService(workouts: .value(workouts), heartRates: heartRates(workouts))
        let viewModel = WorkoutFeedbackViewModel(workout: workouts[0], service: service)
        await viewModel.load()

        guard case .loaded(let result) = viewModel.state else { return XCTFail("应加载成功：\(viewModel.state)") }
        XCTAssertEqual(result.feedback.status, .compared)
        XCTAssertEqual(result.feedback.comparableCount, 4)
        XCTAssertFalse(result.isMergedDuplicate)
        XCTAssertFalse(result.mayMissOlderWorkouts)
        guard case .compared(_, _, _, let direction, _)? = result.feedback.metric(.averageHeartRate)?.outcome else {
            return XCTFail("心率应可比较")
        }
        XCTAssertEqual(direction, .similar)
    }

    func testReadsHeartRatesOnlyForThisAndEarlierSameActivityWorkouts() async {
        let workouts = [ride(10, daysAfterBase: 10)]
            + (1...4).map { ride($0, daysAfterBase: Double($0)) }
            + [ride(20, daysAfterBase: 11), ride(21, daysAfterBase: 9, activity: .running, distanceKm: 8)]
        let service = MockWorkoutHistoryService(workouts: .value(workouts), heartRates: heartRates(workouts))
        let viewModel = WorkoutFeedbackViewModel(workout: workouts[0], service: service)
        await viewModel.load()
        XCTAssertEqual(service.heartRateFetchCount, 5, "本次 + 4 次更早的骑行；之后的骑行和跑步不读取")
    }

    func testWorkoutOutsideLoadedRangeShowsNoData() async {
        let service = MockWorkoutHistoryService(workouts: .value([ride(1, daysAfterBase: 1)]))
        let viewModel = WorkoutFeedbackViewModel(workout: ride(99, daysAfterBase: 0), service: service)
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .noData)
    }

    func testFailureIsReported() async {
        let service = MockWorkoutHistoryService(workouts: .failure(.protectedDataUnavailable))
        let viewModel = WorkoutFeedbackViewModel(workout: ride(1, daysAfterBase: 0), service: service)
        await viewModel.load()
        XCTAssertEqual(viewModel.state, .failed(.protectedDataUnavailable))
    }

    func testFetchLimitReachedFlagsPossiblyMissingOlderWorkouts() async {
        let workouts = [ride(10, daysAfterBase: 10)] + (1...4).map { ride($0, daysAfterBase: Double($0)) }
        let service = MockWorkoutHistoryService(workouts: .value(workouts), heartRates: heartRates(workouts))
        let viewModel = WorkoutFeedbackViewModel(workout: workouts[0], service: service, fetchLimit: 5)
        await viewModel.load()
        XCTAssertEqual(viewModel.state.value?.mayMissOlderWorkouts, true)
    }
}
