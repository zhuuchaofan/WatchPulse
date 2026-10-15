import Foundation
import XCTest
import WatchPulseCore
import WatchPulseShared

@MainActor
final class CyclingSpeedTrackerTests: XCTestCase {
    private let outdoorCycling = WorkoutConfigurationRequest(activity: .cycling, location: .outdoor)

    private func makeController(
        clock: TestClock,
        provider: SimulatedLocationFixProvider
    ) -> (WorkoutSessionController, SimulatedWorkoutSessionDriver, RecordingSender, CyclingSpeedTracker) {
        let driver = SimulatedWorkoutSessionDriver()
        let sender = RecordingSender()
        let controller = WorkoutSessionController(driver: driver, sender: sender, now: { clock.date })
        let tracker = CyclingSpeedTracker(provider: provider, now: { clock.date })
        tracker.onUpdate = { [weak controller] in controller?.refreshMetrics() }
        controller.addObserver(tracker)
        return (controller, driver, sender, tracker)
    }

    private func fix(_ clock: TestClock, speed: Double) -> LocationFix {
        LocationFix(timestamp: clock.date, speed: speed, speedAccuracy: 0.5, horizontalAccuracy: 5)
    }

    func testOnlyOutdoorCyclingStartsGPS() async {
        for configuration in [
            WorkoutConfigurationRequest(activity: .cycling, location: .indoor),
            WorkoutConfigurationRequest(activity: .running, location: .outdoor),
        ] {
            let clock = TestClock()
            let provider = SimulatedLocationFixProvider()
            let (controller, driver, _, tracker) = makeController(clock: clock, provider: provider)
            await controller.start(configuration)
            clock.advance(3)
            driver.advance(to: clock.date)
            XCTAssertFalse(provider.isUpdating)
            XCTAssertFalse(tracker.isActive)
            XCTAssertNil(controller.latestMetrics?.speed, "非室外骑行不附带速度")
        }
    }

    func testSpeedFlowsIntoMirroredMetrics() async {
        let clock = TestClock()
        let provider = SimulatedLocationFixProvider()
        let (controller, driver, sender, _) = makeController(clock: clock, provider: provider)
        await controller.start(outdoorCycling)
        XCTAssertTrue(provider.isUpdating)

        clock.advance(1)
        provider.emit(fix(clock, speed: 7))
        XCTAssertEqual(controller.latestMetrics?.speed?.metersPerSecond, 7)
        XCTAssertEqual(controller.latestMetrics?.speed?.source, .gps)

        clock.advance(1)
        driver.advance(to: clock.date)
        let lastSent = sender.messages.compactMap { message -> WorkoutMetricsSnapshot? in
            if case .metrics(let metrics) = message { return metrics }
            return nil
        }.last
        XCTAssertEqual(lastSent?.speed?.quality, .good)
        XCTAssertNotNil(lastSent?.heartRateBPM)
    }

    func testUpdatesAreRateLimited() async {
        let clock = TestClock()
        let provider = SimulatedLocationFixProvider()
        let (controller, _, sender, _) = makeController(clock: clock, provider: provider)
        await controller.start(outdoorCycling)
        let base = sender.sent.count
        for step in 1...10 {
            clock.advance(0.2)
            provider.emit(fix(clock, speed: 6 + Double(step) * 0.01))
        }
        // 2 秒内 10 个定位，最多触发约 2 次重发。
        XCTAssertLessThanOrEqual(sender.sent.count - base, 3)
    }

    func testStaleSpeedIsPublishedWithoutValue() async {
        let clock = TestClock()
        let provider = SimulatedLocationFixProvider()
        let (controller, _, _, tracker) = makeController(clock: clock, provider: provider)
        await controller.start(outdoorCycling)
        clock.advance(1)
        provider.emit(fix(clock, speed: 7))
        clock.advance(8)
        tracker.tick()
        XCTAssertEqual(controller.latestMetrics?.speed?.quality, .stale)
        XCTAssertNil(controller.latestMetrics?.speed?.metersPerSecond)
    }

    func testDeniedLocationKeepsWorkoutRunning() async {
        let clock = TestClock()
        let provider = SimulatedLocationFixProvider(authorization: .notDetermined)
        provider.authorizationResponse = .denied
        let (controller, driver, _, _) = makeController(clock: clock, provider: provider)
        await controller.start(outdoorCycling)
        clock.advance(5)
        driver.advance(to: clock.date)
        XCTAssertEqual(controller.phase, .running)
        XCTAssertNotNil(controller.latestMetrics?.heartRateBPM)
        XCTAssertNotNil(controller.latestMetrics?.distanceMeters)
        XCTAssertEqual(controller.latestMetrics?.speed?.quality, .notAuthorized)
        XCTAssertNil(controller.latestMetrics?.speed?.metersPerSecond)
        await controller.end()
        XCTAssertTrue(controller.saveStatus.isSaved)
    }

    func testPauseResumeAndEndStopGPS() async {
        let clock = TestClock()
        let provider = SimulatedLocationFixProvider()
        let (controller, driver, _, _) = makeController(clock: clock, provider: provider)
        await controller.start(outdoorCycling)
        clock.advance(1)
        provider.emit(fix(clock, speed: 7))
        controller.pause()
        XCTAssertEqual(controller.phase, .paused)
        clock.advance(1)
        provider.emit(fix(clock, speed: 7))
        driver.advance(to: clock.date)
        XCTAssertEqual(controller.latestMetrics?.speed?.quality, .paused)

        controller.resume()
        clock.advance(1)
        provider.emit(fix(clock, speed: 3))
        XCTAssertEqual(controller.latestMetrics?.speed?.metersPerSecond, 3)

        await controller.end()
        XCTAssertFalse(provider.isUpdating)
        XCTAssertEqual(provider.stopCount, 1)
    }

    func testRecoveredCyclingWorkoutRestartsGPS() async {
        let clock = TestClock()
        let provider = SimulatedLocationFixProvider()
        let driver = SimulatedWorkoutSessionDriver()
        driver.recoverableSnapshot = WorkoutStateSnapshot(
            configuration: outdoorCycling, phase: .running, startDate: clock.date.addingTimeInterval(-600),
            metrics: WorkoutMetricsSnapshot(timestamp: clock.date, elapsedTime: 600)
        )
        let controller = WorkoutSessionController(driver: driver, sender: nil, now: { clock.date })
        let tracker = CyclingSpeedTracker(provider: provider, now: { clock.date })
        controller.addObserver(tracker)
        await controller.recoverIfNeeded()
        XCTAssertTrue(provider.isUpdating)
        XCTAssertTrue(tracker.isActive)
    }

    func testSimulatedTrackProducesFilteredSpeeds() async {
        let clock = TestClock()
        let provider = SimulatedLocationFixProvider()
        let (controller, driver, _, _) = makeController(clock: clock, provider: provider)
        await controller.start(outdoorCycling)
        var speeds: [Double] = []
        for _ in 0..<120 {
            clock.advance(1)
            provider.advance(to: clock.date)
            driver.advance(to: clock.date)
            if let value = controller.latestMetrics?.speed?.metersPerSecond { speeds.append(value) }
        }
        XCTAssertGreaterThan(speeds.count, 100)
        // 第 61 秒的 25 m/s 跳点被过滤。
        XCTAssertLessThan(speeds.max() ?? 0, 9)
    }
}
