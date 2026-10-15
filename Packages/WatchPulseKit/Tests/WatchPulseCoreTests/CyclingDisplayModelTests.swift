import Foundation
import XCTest
import WatchPulseCore
import WatchPulseShared

final class CyclingDisplayModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let outdoor = WorkoutConfigurationRequest(activity: .cycling, location: .outdoor)
    private let zones = try! HeartRateZoneSettings.percentOfMaximum(190)

    private func metrics(speed: WorkoutSpeedSample?, heartRate: Double? = 148, distance: Double? = 12_600, elapsed: TimeInterval = 1_887) -> WorkoutMetricsSnapshot {
        WorkoutMetricsSnapshot(timestamp: now, elapsedTime: elapsed, heartRateBPM: heartRate, distanceMeters: distance, speed: speed)
    }

    private func model(_ metrics: WorkoutMetricsSnapshot?, phase: WorkoutSessionPhase = .running, link: Bool = true, zones: HeartRateZoneSettings? = nil, configuration: WorkoutConfigurationRequest? = nil) -> CyclingDisplayModel {
        CyclingDisplayModel(configuration: configuration ?? outdoor, metrics: metrics, phase: phase, zones: zones, targetZone: .z3, isLinkHealthy: link, now: now)
    }

    func testLiveSpeed() {
        let speed = WorkoutSpeedSample(metersPerSecond: 7.444, sampleDate: now.addingTimeInterval(-2), source: .gps, quality: .good)
        let display = model(metrics(speed: speed), zones: zones)
        XCTAssertEqual(display.speedText, "26.8")
        XCTAssertEqual(display.speedStatusText, "GPS 有效 · 2秒前")
        XCTAssertTrue(display.isSpeedLive)
        XCTAssertEqual(display.averageSpeedText, "24.0")
        XCTAssertEqual(display.distanceText, "12.60 公里")
        XCTAssertEqual(display.heartRateText, "148")
        XCTAssertEqual(display.zone, .z3)
        XCTAssertEqual(display.zoneText, "Z3 有氧")
    }

    func testTrueStandstillShowsZero() {
        let speed = WorkoutSpeedSample(metersPerSecond: 0, sampleDate: now, source: .gps, quality: .good)
        XCTAssertEqual(model(metrics(speed: speed)).speedText, "0.0")
    }

    func testMissingOrInvalidSpeedNeverShowsZero() {
        let cases: [(WorkoutSpeedSample?, String)] = [
            (nil, "等待速度数据"),
            (.unavailable(.unavailable), "无定位"),
            (.unavailable(.notAuthorized), "未授权定位"),
            (.unavailable(.stale, source: .gps, sampleDate: now.addingTimeInterval(-30)), "信号丢失"),
            // 数值本身有效，但到达 iPhone 时已过期。
            (WorkoutSpeedSample(metersPerSecond: 7, sampleDate: now.addingTimeInterval(-30), source: .gps, quality: .good), "信号丢失"),
        ]
        for (speed, status) in cases {
            let display = model(metrics(speed: speed))
            XCTAssertEqual(display.speedText, "--")
            XCTAssertEqual(display.speedStatusText, status)
            XCTAssertFalse(display.isSpeedLive)
        }
    }

    func testPausedAndDisconnected() {
        let speed = WorkoutSpeedSample(metersPerSecond: 7, sampleDate: now, source: .gps, quality: .good)
        XCTAssertEqual(model(metrics(speed: speed), phase: .paused).speedStatusText, "已暂停")
        XCTAssertEqual(model(metrics(speed: speed), phase: .paused).speedText, "--")
        let disconnected = model(metrics(speed: speed), link: false)
        XCTAssertEqual(disconnected.speedText, "--")
        XCTAssertEqual(disconnected.speedStatusText, "连接中断")
    }

    func testLowAccuracyIsLabelled() {
        let speed = WorkoutSpeedSample(metersPerSecond: 5, sampleDate: now, source: .gps, quality: .lowAccuracy)
        XCTAssertEqual(model(metrics(speed: speed)).speedStatusText, "GPS 精度低 · 0秒前")
    }

    func testIndoorCycling() {
        let display = model(metrics(speed: nil, distance: nil), configuration: WorkoutConfigurationRequest(activity: .cycling, location: .indoor))
        XCTAssertEqual(display.speedStatusText, "室内骑行无 GPS 速度")
        XCTAssertEqual(display.averageSpeedText, "--")
        XCTAssertEqual(display.distanceText, "--")
    }

    func testZoneTexts() {
        XCTAssertEqual(model(metrics(speed: nil, heartRate: 90), zones: zones).zoneText, "低于 Z1")
        XCTAssertNil(model(metrics(speed: nil, heartRate: 90), zones: zones).zone)
        XCTAssertEqual(model(metrics(speed: nil), zones: nil).zoneText, "未设置心率区间")
        XCTAssertEqual(model(metrics(speed: nil, heartRate: nil), zones: zones).heartRateText, "--")
        XCTAssertEqual(model(nil, zones: zones).zoneText, "等待心率")
    }

    func testStartOfWorkout() {
        let display = model(WorkoutMetricsSnapshot(timestamp: now, elapsedTime: 0))
        XCTAssertEqual(display.averageSpeedText, "--")
        XCTAssertEqual(display.speedText, "--")
    }
}
