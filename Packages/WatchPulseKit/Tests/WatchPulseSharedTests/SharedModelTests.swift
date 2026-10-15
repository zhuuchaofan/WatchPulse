import Foundation
import XCTest
import WatchPulseShared

final class SharedModelTests: XCTestCase {
    func testHeartRateSampleCodableRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = HeartRateSample(
            id: UUID(),
            beatsPerMinute: 58,
            startDate: date,
            endDate: date.addingTimeInterval(5),
            source: HealthSampleSource(
                name: "Apple Watch",
                bundleIdentifier: "com.apple.health.ABC",
                productType: "Watch7,1",
                deviceName: "Apple Watch",
                deviceModel: "Watch"
            )
        )

        let decoded = try JSONDecoder().decode(HeartRateSample.self, from: JSONEncoder().encode(sample))

        XCTAssertEqual(decoded, sample)
        XCTAssertEqual(decoded.unit, "count/min")
        XCTAssertFalse(decoded.isInstantaneous)
    }

    func testErrorsHaveUserFacingDescriptions() {
        let errors: [HealthDataError] = [
            .healthDataUnavailable,
            .protectedDataUnavailable,
            .authorizationFailed(reason: "x"),
            .queryFailed(reason: "y"),
        ]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error)")
        }
    }

    func testWorkoutPhaseActivity() {
        XCTAssertTrue(WorkoutSessionPhase.running.isActive)
        XCTAssertTrue(WorkoutSessionPhase.paused.isActive)
        XCTAssertFalse(WorkoutSessionPhase.notStarted.isActive)
        XCTAssertFalse(WorkoutSessionPhase.ended.isActive)
    }
}

final class WorkoutMirroringCodecTests: XCTestCase {
    private let sessionID = UUID()

    private func envelope(_ message: WorkoutMirroringMessage, sequence: UInt64 = 1) -> WorkoutMirroringEnvelope {
        WorkoutMirroringEnvelope(sessionID: sessionID, sequence: sequence, sentAt: Date(timeIntervalSince1970: 1_700_000_000), message: message)
    }

    func testRoundTripAllMessageKinds() throws {
        let metrics = WorkoutMetricsSnapshot(
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            elapsedTime: 100,
            heartRateBPM: 132,
            activeEnergyKilocalories: 12.5,
            distanceMeters: nil
        )
        let messages: [WorkoutMirroringMessage] = [
            .phaseChanged(.running, at: Date(timeIntervalSince1970: 1_700_000_000)),
            .metrics(metrics),
            .stateSync(WorkoutStateSnapshot(
                configuration: WorkoutConfigurationRequest(activity: .cycling, location: .indoor),
                phase: .paused,
                startDate: Date(timeIntervalSince1970: 1_699_999_000),
                metrics: metrics
            )),
            .stateSync(WorkoutStateSnapshot(configuration: nil, phase: .notStarted, startDate: nil, metrics: nil)),
            .heartbeat(at: Date(timeIntervalSince1970: 1_700_000_200)),
            .commandRejected(.pause, reason: "x"),
            .command(.pause),
            .command(.end),
            .requestStateSync,
        ]

        for (index, message) in messages.enumerated() {
            let original = envelope(message, sequence: UInt64(index + 1))
            let data = try WorkoutMirroringCodec.encode(original)
            XCTAssertEqual(try WorkoutMirroringCodec.decode(data), original)
        }
    }

    func testRejectsUnsupportedVersion() throws {
        let future = WorkoutMirroringEnvelope(version: 99, sessionID: sessionID, sequence: 1, sentAt: Date(), message: .requestStateSync)
        let data = try JSONEncoder().encode(future)
        XCTAssertThrowsError(try WorkoutMirroringCodec.decode(data)) { error in
            XCTAssertEqual(error as? WorkoutMirroringCodec.CodecError, .unsupportedVersion(99))
        }
    }

    func testRejectsMalformedPayload() {
        XCTAssertThrowsError(try WorkoutMirroringCodec.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? WorkoutMirroringCodec.CodecError, .malformedPayload)
        }
        let unknownMessage = Data(#"{"version":1,"sessionID":"00000000-0000-0000-0000-000000000000","sequence":1,"sentAt":0,"message":{"teleport":{}}}"#.utf8)
        XCTAssertThrowsError(try WorkoutMirroringCodec.decode(unknownMessage)) { error in
            XCTAssertEqual(error as? WorkoutMirroringCodec.CodecError, .malformedPayload)
        }
    }

    func testRejectsOversizedPayload() {
        let data = Data(repeating: 0x20, count: WorkoutMirroringCodec.maximumPayloadSize + 1)
        XCTAssertThrowsError(try WorkoutMirroringCodec.decode(data)) { error in
            XCTAssertEqual(error as? WorkoutMirroringCodec.CodecError, .payloadTooLarge(data.count))
        }
    }

    func testTypicalMessagesAreSmall() throws {
        let data = try WorkoutMirroringCodec.encode(envelope(.metrics(WorkoutMetricsSnapshot(
            timestamp: Date(), elapsedTime: 3_600, heartRateBPM: 150, activeEnergyKilocalories: 600, distanceMeters: 10_000
        ))))
        XCTAssertLessThan(data.count, 512)
    }

    func testConfigurationRequestCodable() throws {
        let request = WorkoutConfigurationRequest(activity: .running, location: .outdoor)
        let decoded = try JSONDecoder().decode(WorkoutConfigurationRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
    }

    func testElapsedTimeExtrapolation() {
        let metrics = WorkoutMetricsSnapshot(timestamp: Date(timeIntervalSince1970: 100), elapsedTime: 60)
        XCTAssertEqual(metrics.elapsedTime(at: Date(timeIntervalSince1970: 130), isRunning: true), 90)
        XCTAssertEqual(metrics.elapsedTime(at: Date(timeIntervalSince1970: 130), isRunning: false), 60)
        XCTAssertEqual(metrics.elapsedTime(at: Date(timeIntervalSince1970: 50), isRunning: true), 60)
    }
}

final class HeartRateSeriesTests: XCTestCase {
    private func points(_ count: Int, start: Date = Date(timeIntervalSince1970: 0)) -> [HeartRatePoint] {
        (0..<count).map { HeartRatePoint(date: start.addingTimeInterval(Double($0)), beatsPerMinute: Double(100 + $0 % 50)) }
    }

    func testDownsampleKeepsSmallSeriesSorted() {
        let input = points(10).shuffled()
        XCTAssertEqual(HeartRateSeries.downsample(input, maxPoints: 100), points(10))
    }

    func testDownsampleLimitsPointCountAndPreservesAverage() {
        let input = points(10_000)
        let output = HeartRateSeries.downsample(input, maxPoints: 300)
        XCTAssertLessThanOrEqual(output.count, 300)
        XCTAssertGreaterThan(output.count, 250)
        XCTAssertEqual(output.map(\.date), output.map(\.date).sorted())
        let inputAverage = HeartRateSeriesStatistics(points: input)!.average
        let outputAverage = HeartRateSeriesStatistics(points: output)!.average
        XCTAssertEqual(inputAverage, outputAverage, accuracy: 1)
        XCTAssertGreaterThanOrEqual(output.first!.date, input.first!.date)
        XCTAssertLessThanOrEqual(output.last!.date, input.last!.date)
    }

    func testDownsampleEdgeCases() {
        XCTAssertEqual(HeartRateSeries.downsample([], maxPoints: 10), [])
        let sameTime = (0..<20).map { HeartRatePoint(date: Date(timeIntervalSince1970: 5), beatsPerMinute: Double($0)) }
        XCTAssertEqual(HeartRateSeries.downsample(sameTime, maxPoints: 5).count, 20)
        XCTAssertEqual(HeartRateSeries.downsample(points(20), maxPoints: 0).count, 20)
    }

    func testStatistics() {
        let stats = HeartRateSeriesStatistics(points: [
            HeartRatePoint(date: Date(), beatsPerMinute: 90),
            HeartRatePoint(date: Date(), beatsPerMinute: 150),
            HeartRatePoint(date: Date(), beatsPerMinute: 120),
        ])
        XCTAssertEqual(stats?.minimum, 90)
        XCTAssertEqual(stats?.maximum, 150)
        XCTAssertEqual(stats?.average, 120)
        XCTAssertNil(HeartRateSeriesStatistics(points: []))
    }
}

final class CodecRobustnessTests: XCTestCase {
    func testInvalidUTF8IsRejectedNotCrashing() {
        let data = Data([0x7B, 0x22, 0xC3, 0x28, 0xFF, 0xFE, 0x22, 0x7D])
        XCTAssertThrowsError(try WorkoutMirroringCodec.decode(data)) { error in
            XCTAssertEqual(error as? WorkoutMirroringCodec.CodecError, .malformedPayload)
        }
    }

    func testRebasedKeepsElapsedAndMovesTimestampForwardOnly() {
        let metrics = WorkoutMetricsSnapshot(timestamp: Date(timeIntervalSince1970: 100), elapsedTime: 60, heartRateBPM: 120)
        let resumed = metrics.rebased(to: Date(timeIntervalSince1970: 400))
        XCTAssertEqual(resumed.elapsedTime, 60)
        XCTAssertEqual(resumed.elapsedTime(at: Date(timeIntervalSince1970: 410), isRunning: true), 70)
        XCTAssertEqual(metrics.rebased(to: Date(timeIntervalSince1970: 50)).timestamp, metrics.timestamp)
    }
}

final class CodecFuzzTests: XCTestCase {
    func testControlCharactersAndRandomBytesAreRejected() {
        XCTAssertThrowsError(try WorkoutMirroringCodec.decode(Data([0x7B, 0x22, 0x61, 0x04, 0x22, 0x3A, 0x31, 0x7D])))
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let bytes = (0..<Int.random(in: 0...64, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            _ = try? WorkoutMirroringCodec.decode(Data(bytes))
        }
    }
}
