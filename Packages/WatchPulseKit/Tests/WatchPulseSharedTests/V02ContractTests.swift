import Foundation
import XCTest
import WatchPulseShared

/// v0.2 共享契约：新增字段向后 / 向前兼容，区间设置校验。
final class V02ContractTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func encode(_ envelope: WorkoutMirroringEnvelope) throws -> [String: Any] {
        let data = try WorkoutMirroringCodec.encode(envelope)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - 速度字段兼容

    func testLegacyMetricsWithoutSpeedStillDecode() throws {
        // v0.1 Watch 发出的指标消息（没有 speed 字段）。
        let legacy = """
        {"version":1,"sessionID":"00000000-0000-0000-0000-0000000000AA","sequence":3,"sentAt":1800000000,
         "message":{"metrics":{"_0":{"timestamp":1800000000,"elapsedTime":12,"heartRateBPM":120,"distanceMeters":40}}}}
        """
        let envelope = try WorkoutMirroringCodec.decode(Data(legacy.utf8))
        guard case .metrics(let metrics) = envelope.message else { return XCTFail("wrong message") }
        XCTAssertEqual(metrics.heartRateBPM, 120)
        XCTAssertNil(metrics.speed)
    }

    func testSpeedRoundTripsAndOldReadersCanIgnoreIt() throws {
        let speed = WorkoutSpeedSample(metersPerSecond: 7.5, sampleDate: date, source: .gps, quality: .good)
        let metrics = WorkoutMetricsSnapshot(timestamp: date, elapsedTime: 60, heartRateBPM: 140, distanceMeters: 420, speed: speed)
        let envelope = WorkoutMirroringEnvelope(sessionID: UUID(), sequence: 1, sentAt: date, message: .metrics(metrics))
        let decoded = try WorkoutMirroringCodec.decode(WorkoutMirroringCodec.encode(envelope))
        XCTAssertEqual(decoded, envelope)
        // 版本号不变：v0.1 iPhone 会忽略未知字段，而不是拒绝整条消息。
        XCTAssertEqual(try encode(envelope)["version"] as? Int, 1)
    }

    func testUnknownSpeedQualityDegradesToUnavailable() throws {
        let json = """
        {"version":1,"sessionID":"00000000-0000-0000-0000-0000000000AA","sequence":3,"sentAt":1800000000,
         "message":{"metrics":{"_0":{"timestamp":1800000000,"elapsedTime":12,
         "speed":{"metersPerSecond":5,"source":"lidar","quality":"superb"}}}}}
        """
        let envelope = try WorkoutMirroringCodec.decode(Data(json.utf8))
        guard case .metrics(let metrics) = envelope.message else { return XCTFail("wrong message") }
        XCTAssertEqual(metrics.speed?.quality, .unavailable)
        XCTAssertEqual(metrics.speed?.source, .unavailable)
        // 不可展示的质量不能携带数值。
        XCTAssertNil(metrics.speed?.metersPerSecond)
    }

    func testMalformedSpeedDoesNotDropOtherMetrics() throws {
        let json = """
        {"version":1,"sessionID":"00000000-0000-0000-0000-0000000000AA","sequence":3,"sentAt":1800000000,
         "message":{"metrics":{"_0":{"timestamp":1800000000,"elapsedTime":12,"heartRateBPM":99,"speed":"fast"}}}}
        """
        let envelope = try WorkoutMirroringCodec.decode(Data(json.utf8))
        guard case .metrics(let metrics) = envelope.message else { return XCTFail("wrong message") }
        XCTAssertEqual(metrics.heartRateBPM, 99)
        XCTAssertNil(metrics.speed)
    }

    func testStaleSpeedNeverCarriesValue() {
        let stale = WorkoutSpeedSample(metersPerSecond: 8, sampleDate: date, source: .gps, quality: .stale)
        XCTAssertNil(stale.metersPerSecond)
        XCTAssertNil(stale.kilometersPerHour)
        let still = WorkoutSpeedSample(metersPerSecond: 0, sampleDate: date, source: .gps, quality: .good)
        XCTAssertEqual(still.kilometersPerHour, 0)
    }

    func testSpeedFormatting() {
        XCTAssertEqual(MetricFormatting.speedKilometersPerHour(7.444), "26.8")
        XCTAssertEqual(MetricFormatting.speedKilometersPerHour(0), "0.0")
        XCTAssertEqual(MetricFormatting.speedKilometersPerHour(nil), "--")
        XCTAssertEqual(MetricFormatting.speedKilometersPerHour(-1), "--")
        XCTAssertEqual(MetricFormatting.speedKilometersPerHour(.nan), "--")
    }

    func testAverageSpeedDefinition() {
        XCTAssertEqual(WorkoutSpeedMath.averageSpeed(distanceMeters: 12_600, activeDuration: 1_887) ?? 0, 6.677, accuracy: 0.001)
        XCTAssertNil(WorkoutSpeedMath.averageSpeed(distanceMeters: nil, activeDuration: 600))
        XCTAssertNil(WorkoutSpeedMath.averageSpeed(distanceMeters: 100, activeDuration: 0))
        XCTAssertNil(WorkoutSpeedMath.averageSpeed(distanceMeters: 100, activeDuration: 0.5))
        XCTAssertEqual(WorkoutSpeedMath.averageSpeed(distanceMeters: 0, activeDuration: 60), 0)
        let metrics = WorkoutMetricsSnapshot(timestamp: date, elapsedTime: 100, distanceMeters: 500)
        XCTAssertEqual(metrics.averageSpeedMetersPerSecond, 5)
    }

    func testRebaseAndWithSpeedKeepTiming() {
        let speed = WorkoutSpeedSample(metersPerSecond: 5, sampleDate: date, source: .gps, quality: .good)
        let metrics = WorkoutMetricsSnapshot(timestamp: date, elapsedTime: 30, speed: speed)
        XCTAssertEqual(metrics.rebased(to: date.addingTimeInterval(10)).speed, speed)
        let replaced = metrics.with(speed: nil)
        XCTAssertNil(replaced.speed)
        XCTAssertEqual(replaced.timestamp, metrics.timestamp)
        XCTAssertEqual(replaced.elapsedTime, metrics.elapsedTime)
    }

    // MARK: - 区间设置

    func testPercentZonesFromUserMaximum() throws {
        let zones = try HeartRateZoneSettings.percentOfMaximum(190)
        XCTAssertEqual(zones.lowerBounds, [95, 114, 133, 152, 171])
        XCTAssertEqual(zones.range(of: .z1), 95...113)
        XCTAssertEqual(zones.range(of: .z5), 171...190)
        XCTAssertNil(zones.zone(for: 94.9))
        XCTAssertEqual(zones.zone(for: 95), .z1)
        XCTAssertEqual(zones.zone(for: 113.9), .z1)
        XCTAssertEqual(zones.zone(for: 114), .z2)
        XCTAssertEqual(zones.zone(for: 171), .z5)
        XCTAssertEqual(zones.zone(for: 230), .z5)
        XCTAssertNil(zones.zone(for: .nan))
    }

    func testZoneValidation() {
        XCTAssertThrowsError(try HeartRateZoneSettings.percentOfMaximum(90)) {
            XCTAssertEqual($0 as? HeartRateZoneSettings.ValidationError, .maximumOutOfRange)
        }
        XCTAssertThrowsError(try HeartRateZoneSettings(method: .custom, maximumHeartRate: 180, lowerBounds: [100, 120, 140, 160])) {
            XCTAssertEqual($0 as? HeartRateZoneSettings.ValidationError, .wrongBoundaryCount)
        }
        XCTAssertThrowsError(try HeartRateZoneSettings(method: .custom, maximumHeartRate: 180, lowerBounds: [100, 120, 120, 150, 170])) {
            XCTAssertEqual($0 as? HeartRateZoneSettings.ValidationError, .boundariesNotIncreasing)
        }
        XCTAssertThrowsError(try HeartRateZoneSettings(method: .custom, maximumHeartRate: 180, lowerBounds: [100, 120, 140, 160, 180])) {
            XCTAssertEqual($0 as? HeartRateZoneSettings.ValidationError, .boundaryOutOfRange)
        }
        XCTAssertThrowsError(try HeartRateZoneSettings(method: .custom, maximumHeartRate: 180, lowerBounds: [30, 120, 140, 160, 170])) {
            XCTAssertEqual($0 as? HeartRateZoneSettings.ValidationError, .boundaryOutOfRange)
        }
        XCTAssertNoThrow(try HeartRateZoneSettings(method: .custom, maximumHeartRate: 185, lowerBounds: [105, 125, 140, 158, 172]))
    }

    func testInvalidStoredZonesFailToDecode() throws {
        let invalid = Data(#"{"method":"custom","maximumHeartRate":180,"lowerBounds":[150,140,130,120,110]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(HeartRateZoneSettings.self, from: invalid))
    }

    func testStateSyncCarriesZonesAndIgnoresInvalidOnes() throws {
        let zones = try HeartRateZoneSettings.percentOfMaximum(190)
        let snapshot = WorkoutStateSnapshot(
            configuration: WorkoutConfigurationRequest(activity: .cycling, location: .outdoor),
            phase: .running, startDate: date, metrics: nil, heartRateZones: zones, targetZone: .z3
        )
        let envelope = WorkoutMirroringEnvelope(sessionID: UUID(), sequence: 1, sentAt: date, message: .stateSync(snapshot))
        XCTAssertEqual(try WorkoutMirroringCodec.decode(WorkoutMirroringCodec.encode(envelope)), envelope)

        let json = """
        {"version":1,"sessionID":"00000000-0000-0000-0000-0000000000AA","sequence":3,"sentAt":1800000000,
         "message":{"stateSync":{"_0":{"phase":"running","saveStatus":{"pending":{}},
         "heartRateZones":{"method":"custom","maximumHeartRate":180,"lowerBounds":[1,2]},"targetZone":9}}}}
        """
        let decoded = try WorkoutMirroringCodec.decode(Data(json.utf8))
        guard case .stateSync(let state) = decoded.message else { return XCTFail("wrong message") }
        XCTAssertEqual(state.phase, .running)
        XCTAssertNil(state.heartRateZones)
        XCTAssertNil(state.targetZone)
    }

    func testAlertSettingsDefaultOff() {
        let settings = ZoneAlertSettings()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertGreaterThanOrEqual(settings.cooldown, 60)
        XCTAssertGreaterThanOrEqual(settings.sustainDuration, 8)
    }
}
