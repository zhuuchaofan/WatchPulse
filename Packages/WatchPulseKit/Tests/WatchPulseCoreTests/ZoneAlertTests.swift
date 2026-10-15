import Foundation
import XCTest
import WatchPulseCore
import WatchPulseShared

final class ZoneAlertEngineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    // 最大心率 190：Z2 = 114…132。
    private let zones = try! HeartRateZoneSettings.percentOfMaximum(190)
    private var settings = ZoneAlertSettings(isEnabled: true, targetZone: .z2)

    /// 每 `step` 秒一个样本，返回触发的提醒及其时间（秒）。
    private func run(_ engine: inout ZoneAlertEngine, _ samples: [(t: TimeInterval, bpm: Double)], phase: WorkoutSessionPhase = .running) -> [(TimeInterval, ZoneHapticKind)] {
        samples.compactMap { sample in
            let date = t0.addingTimeInterval(sample.t)
            return engine.evaluate(heartRate: sample.bpm, sampleDate: date, phase: phase, now: date, zones: zones, settings: settings)
                .map { (sample.t, $0) }
        }
    }

    private func series(from start: TimeInterval, to end: TimeInterval, step: TimeInterval = 2, bpm: Double) -> [(t: TimeInterval, bpm: Double)] {
        stride(from: start, through: end, by: step).map { (t: $0, bpm: bpm) }
    }

    func testDisabledByDefault() {
        var engine = ZoneAlertEngine()
        settings = ZoneAlertSettings()
        XCTAssertTrue(run(&engine, series(from: 0, to: 60, bpm: 170)).isEmpty)
    }

    func testSustainedExcursionTriggersOnce() {
        var engine = ZoneAlertEngine()
        let alerts = run(&engine, series(from: 0, to: 300, bpm: 150))
        XCTAssertEqual(alerts.count, 1, "持续越界只提醒一次")
        XCTAssertEqual(alerts.first?.1, .aboveZone)
        XCTAssertGreaterThanOrEqual(alerts.first?.0 ?? 0, settings.sustainDuration)
    }

    func testShortExcursionDoesNotTrigger() {
        var engine = ZoneAlertEngine()
        var samples = series(from: 0, to: 6, bpm: 150)  // 6 秒越界
        samples += series(from: 8, to: 60, bpm: 120)
        XCTAssertTrue(run(&engine, samples).isEmpty)
    }

    func testSingleSpikeDoesNotTrigger() {
        var engine = ZoneAlertEngine()
        settings.minimumConsecutiveSamples = 3
        // 只有 2 个越界样本，即使间隔超过持续时间。
        let samples: [(t: TimeInterval, bpm: Double)] = [(0, 150), (12, 150), (14, 120)]
        XCTAssertTrue(run(&engine, samples).isEmpty)
    }

    func testBelowZone() {
        var engine = ZoneAlertEngine()
        let alerts = run(&engine, series(from: 0, to: 30, bpm: 100))
        XCTAssertEqual(alerts.map(\.1), [.belowZone])
    }

    func testHysteresisRequiredBeforeRearming() {
        var engine = ZoneAlertEngine()
        var samples = series(from: 0, to: 20, bpm: 150)            // 提醒
        samples += series(from: 22, to: 100, bpm: 131)              // 刚好回到区间边缘（未超过滞回）
        samples += series(from: 102, to: 200, bpm: 150)             // 再次越界：未武装，不提醒
        XCTAssertEqual(run(&engine, samples).count, 1)

        var engine2 = ZoneAlertEngine()
        var samples2 = series(from: 0, to: 20, bpm: 150)
        samples2 += series(from: 22, to: 100, bpm: 123)             // 回到区间中部，重新武装
        samples2 += series(from: 102, to: 200, bpm: 150)
        XCTAssertEqual(run(&engine2, samples2).count, 2)
    }

    func testCooldownLimitsFrequency() {
        var engine = ZoneAlertEngine()
        settings.cooldown = 60
        var samples = series(from: 0, to: 12, bpm: 150)             // t≈10 提醒
        samples += series(from: 14, to: 20, bpm: 123)                // 回到区间中部
        samples += series(from: 22, to: 50, bpm: 150)                // 冷却中
        let alerts = run(&engine, samples)
        XCTAssertEqual(alerts.count, 1)
        // 冷却结束后若仍越界则提醒。
        let later = run(&engine, series(from: 52, to: 90, bpm: 150))
        XCTAssertEqual(later.count, 1)
        XCTAssertGreaterThanOrEqual((later.first?.0 ?? 0) - (alerts.first?.0 ?? 0), 60)
    }

    func testPausedOrStaleNeverAlerts() {
        var engine = ZoneAlertEngine()
        XCTAssertTrue(run(&engine, series(from: 0, to: 60, bpm: 170), phase: .paused).isEmpty)
        XCTAssertTrue(run(&engine, series(from: 0, to: 60, bpm: 170), phase: .stopped).isEmpty)

        // 样本时间停在 0 秒（心率不再更新）：过期后不提醒。
        var stale = ZoneAlertEngine()
        let sampleDate = t0
        var alerts = 0
        for second in stride(from: 0.0, through: 60, by: 2) {
            if stale.evaluate(heartRate: 170, sampleDate: sampleDate, phase: .running, now: t0.addingTimeInterval(second), zones: zones, settings: settings) != nil {
                alerts += 1
            }
        }
        XCTAssertEqual(alerts, 0)
    }

    func testPauseResetsSustainTimer() {
        var engine = ZoneAlertEngine()
        var alerts = run(&engine, series(from: 0, to: 6, bpm: 150))
        alerts += run(&engine, [(8, 150)], phase: .paused)
        alerts += run(&engine, series(from: 10, to: 16, bpm: 150))
        XCTAssertTrue(alerts.isEmpty, "暂停前后的越界时间不能累加")
    }

    func testWithoutZonesNeverAlerts() {
        var engine = ZoneAlertEngine()
        let date = t0
        XCTAssertNil(engine.evaluate(heartRate: 200, sampleDate: date, phase: .running, now: date, zones: nil, settings: settings))
    }
}

@MainActor
final class ZoneAlertMonitorTests: XCTestCase {
    private func makeStore() -> HeartRateZoneSettingsStore {
        let defaults = UserDefaults(suiteName: "ZoneAlertMonitorTests.\(UUID().uuidString)")!
        return HeartRateZoneSettingsStore(defaults: defaults)
    }

    func testStoreCannotEnableAlertsWithoutZones() async throws {
        let store = makeStore()
        XCTAssertNil(store.zones)
        XCTAssertFalse(store.save(alert: ZoneAlertSettings(isEnabled: true)))
        XCTAssertFalse(store.alert.isEnabled)
        XCTAssertNil(store.activeTargetZone)

        store.save(zones: try .percentOfMaximum(185))
        XCTAssertTrue(store.save(alert: ZoneAlertSettings(isEnabled: true, targetZone: .z3)))
        XCTAssertEqual(store.activeTargetZone, .z3)

        store.resetZones()
        XCTAssertNil(store.zones)
        XCTAssertFalse(store.alert.isEnabled)
    }

    func testStorePersists() async throws {
        let suite = "ZoneAlertMonitorTests.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = HeartRateZoneSettingsStore(defaults: defaults)
        let zones = try HeartRateZoneSettings(method: .custom, maximumHeartRate: 186, lowerBounds: [100, 118, 135, 152, 168])
        store.save(zones: zones)
        store.save(alert: ZoneAlertSettings(isEnabled: true, targetZone: .z2))

        let reloaded = HeartRateZoneSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.zones, zones)
        XCTAssertEqual(reloaded.activeTargetZone, .z2)
    }

    func testCorruptStoredZonesAreTreatedAsUnset() async {
        let defaults = UserDefaults(suiteName: "ZoneAlertMonitorTests.corrupt.\(UUID().uuidString)")!
        defaults.set(Data(#"{"method":"custom","maximumHeartRate":180,"lowerBounds":[1]}"#.utf8), forKey: HeartRateZoneSettingsStore.zonesKey)
        defaults.set(try? JSONEncoder().encode(ZoneAlertSettings(isEnabled: true)), forKey: HeartRateZoneSettingsStore.alertKey)
        let store = HeartRateZoneSettingsStore(defaults: defaults)
        XCTAssertNil(store.zones)
        XCTAssertFalse(store.alert.isEnabled)
    }

    func testMonitorPlaysHapticDuringWorkout() async throws {
        let clock = TestClock()
        let store = makeStore()
        store.save(zones: try .percentOfMaximum(190))
        // 目标 Z1（95–113）：模拟运动热身后心率高于 Z1，应提醒“高于区间”。
        store.save(alert: ZoneAlertSettings(isEnabled: true, targetZone: .z1))
        let haptics = RecordingHapticPlayer()
        let monitor = ZoneAlertMonitor(store: store, haptics: haptics, now: { clock.date })
        let driver = SimulatedWorkoutSessionDriver()
        let controller = WorkoutSessionController(driver: driver, sender: nil, now: { clock.date })
        controller.addObserver(monitor)

        await controller.start(WorkoutConfigurationRequest(activity: .cycling, location: .outdoor))
        for _ in 0..<600 {
            clock.advance(1)
            driver.advance(to: clock.date)
        }
        // 热身时低于 Z1（提醒一次“低于”），升温穿过 Z1 后高于 Z1（再提醒一次“高于”），之后持续越界不再提醒。
        XCTAssertEqual(haptics.played, [.belowZone, .aboveZone])
        XCTAssertEqual(monitor.alertCount, haptics.played.count)

        controller.pause()
        let countAtPause = haptics.played.count
        for _ in 0..<120 {
            clock.advance(1)
            driver.advance(to: clock.date)
        }
        XCTAssertEqual(haptics.played.count, countAtPause, "暂停期间不提醒")
        await controller.end()
    }

    func testMonitorSilentWhenDisabled() async throws {
        let clock = TestClock()
        let store = makeStore()
        store.save(zones: try .percentOfMaximum(190))
        let haptics = RecordingHapticPlayer()
        let monitor = ZoneAlertMonitor(store: store, haptics: haptics, now: { clock.date })
        let driver = SimulatedWorkoutSessionDriver()
        let controller = WorkoutSessionController(driver: driver, sender: nil, now: { clock.date })
        controller.addObserver(monitor)
        await controller.start(WorkoutConfigurationRequest(activity: .cycling, location: .outdoor))
        for _ in 0..<300 {
            clock.advance(1)
            driver.advance(to: clock.date)
        }
        XCTAssertTrue(haptics.played.isEmpty)
    }
}
