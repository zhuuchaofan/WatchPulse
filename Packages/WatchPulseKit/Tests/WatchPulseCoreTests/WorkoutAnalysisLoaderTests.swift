import Foundation
import XCTest
@testable import WatchPulseCore
import WatchPulseShared

final class WorkoutAnalysisLoaderTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_772_359_200)

    private let native = WorkoutSourceInfo(
        name: "体能训练", bundleIdentifier: "com.apple.health.X",
        deviceName: "Apple Watch", deviceModel: "Watch", deviceHardwareVersion: "Watch6,1"
    )

    private func workout(_ n: Int, dayOffset: Double = 0, source: WorkoutSourceInfo? = nil, minutes: Double = 30) -> WorkoutRecord {
        let start = base.addingTimeInterval(dayOffset * 86_400)
        let info = source ?? native
        return WorkoutRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
            activity: .cycling, location: .outdoor,
            startDate: start, endDate: start.addingTimeInterval(minutes * 60), duration: minutes * 60,
            distanceMeters: 10_000, sourceName: info.name, sourceInfo: info
        )
    }

    private func points(for workout: WorkoutRecord, bpm: Double = 140) -> [HeartRatePoint] {
        stride(from: 0.0, through: workout.duration, by: 5).map {
            HeartRatePoint(date: workout.startDate.addingTimeInterval($0), beatsPerMinute: bpm)
        }
    }

    private func service(_ workouts: [WorkoutRecord], failing: Set<UUID> = [], attributions: [UUID: HeartRateAttribution] = [:]) -> MockWorkoutHistoryService {
        var heartRates: [UUID: MockHealthDataService.Behavior<[HeartRatePoint]>] = [:]
        for workout in workouts {
            heartRates[workout.id] = failing.contains(workout.id) ? .failure(.queryFailed(reason: "boom")) : .value(points(for: workout))
        }
        return MockWorkoutHistoryService(workouts: .value(workouts), heartRates: heartRates, attributions: attributions)
    }

    func testFetchesHeartRateOnlyForPrimaryRecords() async throws {
        let a = workout(1, source: WorkoutSourceInfo(name: "体能训练", bundleIdentifier: "com.apple.health.X", externalIdentifier: "E"))
        let b = workout(2, source: WorkoutSourceInfo(name: "Strava", bundleIdentifier: "com.strava", externalIdentifier: "E"))
        let c = workout(3, dayOffset: -2)
        let mock = service([a, b, c])
        let set = try await WorkoutAnalysisLoader(service: mock).load(limit: 50)
        XCTAssertEqual(set.records.count, 2)
        XCTAssertEqual(mock.heartRateFetchCount, 2, "确认重复只为主记录读取心率")
    }

    func testOneHeartRateFailureOnlyDowngradesThatRecord() async throws {
        let a = workout(1), b = workout(2, dayOffset: -1)
        let mock = service([a, b], failing: [b.id])
        let set = try await WorkoutAnalysisLoader(service: mock).load(limit: 50)
        let first = try XCTUnwrap(set.records.first { $0.id == a.id })
        let second = try XCTUnwrap(set.records.first { $0.id == b.id })
        XCTAssertEqual(first.heartRate.usability, .comparable)
        XCTAssertEqual(second.heartRate.usability, .unavailable)
        XCTAssertTrue(second.heartRate.reasons.contains(.notLoaded))
        XCTAssertTrue(second.eligibility.canCountInStatistics, "心率读取失败不影响次数 / 时长统计")
    }

    func testHeartRateBudgetLimitsQueriesToMostRecentWorkouts() async throws {
        let all = (1...6).map { workout($0, dayOffset: -Double($0)) }
        let mock = service(all)
        let set = try await WorkoutAnalysisLoader(service: mock, maximumHeartRateFetches: 2).load(limit: 50)
        XCTAssertEqual(mock.heartRateFetchCount, 2)
        let loaded = set.records.filter { $0.heartRate.usability != .unavailable }.map(\.id)
        XCTAssertEqual(Set(loaded), [all[0].id, all[1].id], "只读取最近的运动")
        XCTAssertEqual(set.records.count, 6, "未读取心率的记录仍然在分析集合里")
    }

    func testWorkoutQueryFailurePropagates() async {
        let mock = MockWorkoutHistoryService(workouts: .failure(.protectedDataUnavailable))
        do {
            _ = try await WorkoutAnalysisLoader(service: mock).load(limit: 10)
            XCTFail("应抛出错误")
        } catch let error as HealthDataError {
            XCTAssertEqual(error, .protectedDataUnavailable)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAttributionFromServiceDrivesUsability() async throws {
        let a = workout(1)
        let mock = service([a], attributions: [a.id: .timeRangeAllSources])
        let set = try await WorkoutAnalysisLoader(service: mock).load(limit: 10)
        XCTAssertEqual(set.records[0].heartRate.usability, .displayOnly)
        XCTAssertEqual(set.records[0].heartRate.attribution, .timeRangeAllSources)
    }

    func testOriginFollowsServiceSoDemoDataStaysLabelled() async throws {
        let set = try await WorkoutAnalysisLoader(service: MockWorkoutHistoryService.demo(count: 4)).load(limit: 10)
        XCTAssertEqual(set.origin, .simulated)
        XCTAssertTrue(set.records.allSatisfy(\.isSimulated))
    }

    func testPersonalZonesOnlyWhenProviderReturnsUserSettings() async throws {
        let a = workout(1)
        let loaderWithout = WorkoutAnalysisLoader(service: service([a]))
        let without = try await loaderWithout.load(limit: 10)
        XCTAssertNil(without.records[0].personalZones)

        let settings = try HeartRateZoneSettings.percentOfMaximum(190)
        let loaderWith = WorkoutAnalysisLoader(service: service([a]), zoneSettings: { settings })
        let with = try await loaderWith.load(limit: 10)
        XCTAssertEqual(with.records[0].personalZones?.basis, .personal(settings))
    }

    func testEmptyHistoryGivesEmptySet() async throws {
        let set = try await WorkoutAnalysisLoader(service: MockWorkoutHistoryService()).load(limit: 10)
        XCTAssertTrue(set.records.isEmpty)
    }
}

@MainActor
final class WorkoutAnalysisViewModelTests: XCTestCase {
    func testStatesFollowService() async {
        let empty = WorkoutAnalysisViewModel(loader: WorkoutAnalysisLoader(service: MockWorkoutHistoryService()))
        await empty.load()
        XCTAssertEqual(empty.state, .noData)

        let failing = WorkoutAnalysisViewModel(loader: WorkoutAnalysisLoader(service: MockWorkoutHistoryService(workouts: .failure(.protectedDataUnavailable))))
        await failing.load()
        XCTAssertEqual(failing.state, .failed(.protectedDataUnavailable))

        let unavailable = WorkoutAnalysisViewModel(loader: WorkoutAnalysisLoader(service: MockWorkoutHistoryService(isHealthDataAvailable: false)))
        await unavailable.load()
        XCTAssertEqual(unavailable.state, .healthDataUnavailable)

        let loaded = WorkoutAnalysisViewModel(loader: WorkoutAnalysisLoader(service: MockWorkoutHistoryService.demo(count: 5)))
        await loaded.load()
        XCTAssertEqual(loaded.state.value?.records.count, 5)
        XCTAssertEqual(loaded.state.value?.origin, .simulated)
    }
}

@MainActor
final class WorkoutDetailBasisTests: XCTestCase {
    func testDetailLabelsSessionRelativeZonesAndCarriesEvidence() async throws {
        let workout = SimulatedWorkoutHistory.workouts(endingBefore: Date(timeIntervalSince1970: 1_800_000_000), count: 1)[0]
        let service = MockWorkoutHistoryService.demo(now: Date(timeIntervalSince1970: 1_800_000_000), count: 1)
        let viewModel = WorkoutDetailViewModel(workout: workout, service: service)
        await viewModel.load()
        let detail = try XCTUnwrap(viewModel.state.value)
        XCTAssertEqual(detail.zoneBasis.kind, .sessionRelative)
        XCTAssertEqual(detail.zoneBasis.maximumHeartRate, Int(detail.statistics.maximum.rounded()))
        XCTAssertFalse(detail.zoneBasis.isUserConfirmedMaximum)
        XCTAssertEqual(detail.heartRateEvidence.attribution, .workoutAssociated)
        XCTAssertEqual(detail.heartRateEvidence.usability, .comparable)
        XCTAssertFalse(detail.zoneDurations.isEmpty, "保持原有的本次相对区间分布")
    }

    func testDetailEvidenceReflectsNonExactAttribution() async throws {
        let workout = SimulatedWorkoutHistory.workouts(endingBefore: Date(timeIntervalSince1970: 1_800_000_000), count: 1)[0]
        let service = MockWorkoutHistoryService(
            workouts: .value([workout]),
            heartRates: [workout.id: .value(SimulatedWorkoutHistory.heartRates(for: workout))],
            attributions: [workout.id: .timeRangeAllSources]
        )
        let viewModel = WorkoutDetailViewModel(workout: workout, service: service)
        await viewModel.load()
        let detail = try XCTUnwrap(viewModel.state.value)
        XCTAssertEqual(detail.heartRateEvidence.usability, .displayOnly)
        XCTAssertEqual(detail.attribution, .timeRangeAllSources)
    }
}
