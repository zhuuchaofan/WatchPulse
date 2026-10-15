import Foundation
import XCTest
import WatchPulseCore
import WatchPulseShared

@MainActor
final class CyclingAverageSpeedTests: XCTestCase {
    private let cycling = WorkoutConfigurationRequest(activity: .cycling, location: .outdoor)

    func testAverageSpeedExcludesPausedTime() async {
        let clock = TestClock()
        let driver = SimulatedWorkoutSessionDriver()
        let controller = WorkoutSessionController(driver: driver, sender: nil, now: { clock.date })
        await controller.start(cycling)
        clock.advance(600)
        driver.advance(to: clock.date)
        let before = controller.latestMetrics?.averageSpeedMetersPerSecond
        controller.pause()
        clock.advance(300)
        controller.resume()
        clock.advance(1)
        driver.advance(to: clock.date)
        let metrics = try? XCTUnwrap(controller.latestMetrics)
        XCTAssertEqual(metrics?.elapsedTime ?? 0, 601, accuracy: 0.01, "暂停 5 分钟不计入运动时长")
        let average = try? XCTUnwrap(metrics?.averageSpeedMetersPerSecond)
        XCTAssertEqual(average ?? 0, (metrics?.distanceMeters ?? 0) / 601, accuracy: 0.001)
        XCTAssertEqual(average ?? 0, before ?? 0, accuracy: 0.05, "暂停不应拉低运动均速")
    }

    func testAverageSpeedUnavailableAtStartAndWithoutDistance() async {
        let clock = TestClock()
        let driver = SimulatedWorkoutSessionDriver()
        let controller = WorkoutSessionController(driver: driver, sender: nil, now: { clock.date })
        await controller.start(cycling)
        XCTAssertNil(controller.latestMetrics?.averageSpeedMetersPerSecond, "0 秒时不显示均速")

        let hiit = WorkoutSessionController(driver: SimulatedWorkoutSessionDriver(), sender: nil, now: { clock.date })
        await hiit.start(WorkoutConfigurationRequest(activity: .highIntensityIntervalTraining, location: .indoor))
        XCTAssertNil(hiit.latestMetrics?.averageSpeedMetersPerSecond)
    }

    func testPhoneSeesSameAverageAfterReconnect() async {
        let clock = TestClock()
        let simulation = SimulatedMirroredWorkout(
            monitor: LiveWorkoutMonitor(dataOrigin: .simulated, now: { clock.date }),
            now: { clock.date },
            sleep: { _ in await Task.yield() }
        )
        await simulation.start(cycling)
        clock.advance(120)
        simulation.tick()
        simulation.beginOutage()
        clock.advance(30)
        simulation.tick()
        simulation.endOutage()
        await simulation.watch.waitForPendingWork()
        clock.advance(1)
        simulation.tick()
        XCTAssertEqual(
            simulation.monitor.latestMetrics?.averageSpeedMetersPerSecond,
            simulation.watch.latestMetrics?.averageSpeedMetersPerSecond
        )
    }
}

final class CyclingStatisticsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ activity: WorkoutActivityKind, day: Int, duration: TimeInterval, distance: Double?) -> WorkoutRecord {
        let start = t0.addingTimeInterval(TimeInterval(day) * 86_400)
        return WorkoutRecord(
            id: UUID(), activity: activity, location: .outdoor, startDate: start,
            endDate: start.addingTimeInterval(duration), duration: duration, distanceMeters: distance, sourceName: "test"
        )
    }

    func testRecordAverageSpeed() {
        XCTAssertEqual(record(.cycling, day: 0, duration: 3_600, distance: 25_000).averageSpeedMetersPerSecond ?? 0, 6.944, accuracy: 0.001)
        XCTAssertNil(record(.cycling, day: 0, duration: 3_600, distance: nil).averageSpeedMetersPerSecond)
        XCTAssertNil(record(.cycling, day: 0, duration: 0, distance: 100).averageSpeedMetersPerSecond)
    }

    func testStatisticsOnlyCountCyclingInInterval() throws {
        let workouts = [
            record(.cycling, day: 0, duration: 3_600, distance: 30_000),
            record(.cycling, day: 1, duration: 1_800, distance: 10_000),
            record(.cycling, day: 2, duration: 1_200, distance: nil), // 室内骑行台，无距离
            record(.running, day: 1, duration: 1_800, distance: 5_000),
            record(.cycling, day: 40, duration: 3_600, distance: 40_000), // 区间外
        ]
        let interval = DateInterval(start: t0, duration: 30 * 86_400)
        let stats = try XCTUnwrap(CyclingStatistics(workouts: workouts, interval: interval))
        XCTAssertEqual(stats.rideCount, 3)
        XCTAssertEqual(stats.totalDistanceMeters, 40_000)
        XCTAssertEqual(stats.totalDuration, 6_600)
        // 均速只用有距离的骑行：40 km / 1.5 h。
        XCTAssertEqual(stats.averageSpeedMetersPerSecond ?? 0, 40_000 / 5_400, accuracy: 0.001)
        XCTAssertEqual(stats.longestRideMeters, 30_000)
    }

    func testNoRidesOrNoDistance() {
        let interval = DateInterval(start: t0, duration: 30 * 86_400)
        XCTAssertNil(CyclingStatistics(workouts: [record(.running, day: 0, duration: 60, distance: 100)], interval: interval))
        let indoorOnly = CyclingStatistics(workouts: [record(.cycling, day: 0, duration: 1_800, distance: nil)], interval: interval)
        XCTAssertEqual(indoorOnly?.rideCount, 1)
        XCTAssertNil(indoorOnly?.averageSpeedMetersPerSecond, "没有距离时不显示均速，而不是 0")
        XCTAssertNil(indoorOnly?.longestRideMeters)
    }
}
