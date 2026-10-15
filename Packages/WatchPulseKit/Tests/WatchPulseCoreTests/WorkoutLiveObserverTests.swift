import Foundation
import XCTest
import WatchPulseCore
import WatchPulseShared

/// 记录调用顺序、可补充速度的观察者。
@MainActor
final class RecordingObserver: WorkoutLiveObserver {
    var events: [String] = []
    var speed: WorkoutSpeedSample?
    var tamperWithTiming = false

    func workoutDidStart(_ configuration: WorkoutConfigurationRequest, at date: Date) { events.append("start:\(configuration.activity.rawValue)") }
    func workoutPhaseDidChange(to phase: WorkoutSessionPhase, at date: Date) { events.append("phase:\(phase.rawValue)") }
    func workoutDidEnd() { events.append("end") }
    func workoutMetricsWillPublish(_ metrics: WorkoutMetricsSnapshot) -> WorkoutMetricsSnapshot {
        if tamperWithTiming {
            return WorkoutMetricsSnapshot(timestamp: metrics.timestamp.addingTimeInterval(5), elapsedTime: 0)
        }
        return metrics.with(speed: speed)
    }
}

@MainActor
final class WorkoutLiveObserverTests: XCTestCase {
    private let cycling = WorkoutConfigurationRequest(activity: .cycling, location: .outdoor)

    func testObserverLifecycleDoesNotChangeEndFlow() async {
        let clock = TestClock()
        let driver = SimulatedWorkoutSessionDriver()
        let sender = RecordingSender()
        let controller = WorkoutSessionController(driver: driver, sender: sender, now: { clock.date })
        let observer = RecordingObserver()
        controller.addObserver(observer)

        await controller.start(cycling)
        clock.advance(10)
        controller.pause()
        clock.advance(5)
        controller.resume()
        await controller.end()

        XCTAssertEqual(observer.events.first, "start:cycling")
        XCTAssertTrue(observer.events.contains("phase:paused"))
        XCTAssertTrue(observer.events.contains("end"))
        // 原有结束 / 保存流程不变。
        XCTAssertEqual(driver.lifecycleLog, ["start", "stopAndSave", "endSession"])
        XCTAssertTrue(controller.saveStatus.isSaved)
        XCTAssertEqual(controller.finalStateDelivered, true)
    }

    func testMetricsAreAugmentedBeforeSending() async {
        let clock = TestClock()
        let driver = SimulatedWorkoutSessionDriver()
        let sender = RecordingSender()
        let controller = WorkoutSessionController(driver: driver, sender: sender, now: { clock.date })
        let observer = RecordingObserver()
        let speed = WorkoutSpeedSample(metersPerSecond: 6, sampleDate: clock.date, source: .gps, quality: .good)
        observer.speed = speed
        controller.addObserver(observer)

        await controller.start(cycling)
        clock.advance(5)
        driver.advance(to: clock.date)

        XCTAssertEqual(controller.latestMetrics?.speed, speed)
        let sentMetrics = sender.messages.compactMap { message -> WorkoutMetricsSnapshot? in
            if case .metrics(let metrics) = message { return metrics }
            return nil
        }
        XCTAssertEqual(sentMetrics.last?.speed, speed)
    }

    func testRefreshMetricsResendsWithSameTimestamp() async {
        let clock = TestClock()
        let driver = SimulatedWorkoutSessionDriver()
        let sender = RecordingSender()
        let controller = WorkoutSessionController(driver: driver, sender: sender, now: { clock.date })
        let observer = RecordingObserver()
        controller.addObserver(observer)
        await controller.start(cycling)
        clock.advance(5)
        driver.advance(to: clock.date)
        let before = controller.latestMetrics
        let count = sender.sent.count

        observer.speed = WorkoutSpeedSample(metersPerSecond: 4, sampleDate: clock.date, source: .gps, quality: .good)
        controller.refreshMetrics()

        XCTAssertEqual(sender.sent.count, count + 1)
        XCTAssertEqual(controller.latestMetrics?.timestamp, before?.timestamp)
        XCTAssertEqual(controller.latestMetrics?.elapsedTime, before?.elapsedTime)
        XCTAssertEqual(controller.latestMetrics?.speed?.metersPerSecond, 4)

        // 没有变化不重复发送。
        controller.refreshMetrics()
        XCTAssertEqual(sender.sent.count, count + 1)
    }

    func testObserverCannotChangeTiming() async {
        let clock = TestClock()
        let driver = SimulatedWorkoutSessionDriver()
        let controller = WorkoutSessionController(driver: driver, sender: nil, now: { clock.date })
        let observer = RecordingObserver()
        observer.tamperWithTiming = true
        controller.addObserver(observer)
        await controller.start(cycling)
        clock.advance(5)
        driver.advance(to: clock.date)
        XCTAssertEqual(controller.latestMetrics?.timestamp, clock.date)
        XCTAssertEqual(controller.latestMetrics?.elapsedTime ?? 0, 5, accuracy: 0.001)
    }

    func testRecoveryNotifiesObservers() async {
        let clock = TestClock()
        let driver = SimulatedWorkoutSessionDriver()
        driver.recoverableSnapshot = WorkoutStateSnapshot(
            configuration: cycling, phase: .paused, startDate: clock.date.addingTimeInterval(-60),
            metrics: WorkoutMetricsSnapshot(timestamp: clock.date, elapsedTime: 60)
        )
        let controller = WorkoutSessionController(driver: driver, sender: nil, now: { clock.date })
        let observer = RecordingObserver()
        controller.addObserver(observer)
        await controller.recoverIfNeeded()
        XCTAssertEqual(observer.events, ["start:cycling", "phase:paused"])
    }

    func testZonesAreSyncedToPhone() async throws {
        let clock = TestClock()
        let simulation = SimulatedMirroredWorkout(
            monitor: LiveWorkoutMonitor(dataOrigin: .simulated, now: { clock.date }),
            now: { clock.date },
            sleep: { _ in await Task.yield() }
        )
        let zones = try HeartRateZoneSettings.percentOfMaximum(185)
        simulation.watch.heartRateZones = zones
        simulation.watch.targetZone = .z2
        await simulation.start(cycling)

        XCTAssertEqual(simulation.monitor.heartRateZones, zones)
        XCTAssertEqual(simulation.monitor.targetZone, .z2)

        await simulation.watch.end()
        simulation.monitor.reset()
        XCTAssertNil(simulation.monitor.heartRateZones)
    }
}

final class SleepNightsServiceTests: XCTestCase {
    func testMockSleepNightsFilteredByInterval() async throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = MockHealthDataService.demo(now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let interval = DateInterval(start: calendar.date(byAdding: .day, value: -6, to: today)!, end: calendar.date(byAdding: .day, value: 1, to: today)!)
        let nights = try await service.fetchSleepNights(in: interval)
        XCTAssertEqual(nights.count, 7)
        XCTAssertEqual(nights.map(\.date), nights.map(\.date).sorted())
        XCTAssertTrue(nights.allSatisfy { interval.contains($0.date) })
        XCTAssertEqual(Set(nights.map(\.start)).count, nights.count, "模拟数据的入睡时间每晚应不同")

        let empty = MockHealthDataService()
        let none = try await empty.fetchSleepNights(in: interval)
        XCTAssertTrue(none.isEmpty)
    }
}

@MainActor
final class WorkoutLiveObserverStartFailureTests: XCTestCase {
    func testStartFailureEndsObserver() async {
        let driver = SimulatedWorkoutSessionDriver()
        driver.startError = .sessionStartFailed(reason: "test")
        let controller = WorkoutSessionController(driver: driver, sender: nil)
        let observer = RecordingObserver()
        controller.addObserver(observer)
        await controller.start(WorkoutConfigurationRequest(activity: .cycling, location: .outdoor))
        XCTAssertEqual(observer.events, ["start:cycling", "end"])
    }
}
