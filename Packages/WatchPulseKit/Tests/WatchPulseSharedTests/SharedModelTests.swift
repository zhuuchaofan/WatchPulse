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
    func testRoundTripAllMessageKinds() throws {
        let messages: [WorkoutMirroringMessage] = [
            .phaseChanged(.running, at: Date(timeIntervalSince1970: 1_700_000_000)),
            .metrics(WorkoutMetricsSnapshot(
                timestamp: Date(timeIntervalSince1970: 1_700_000_100),
                elapsedTime: 100,
                heartRateBPM: 132,
                activeEnergyKilocalories: 12.5,
                distanceMeters: nil
            )),
            .command(.pause),
            .command(.end),
        ]

        for message in messages {
            let data = try WorkoutMirroringCodec.encode(message)
            XCTAssertEqual(try WorkoutMirroringCodec.decode(data), message)
        }
    }

    func testRejectsUnsupportedVersion() throws {
        let data = Data(#"{"version":99,"message":{"command":{"_0":"pause"}}}"#.utf8)
        XCTAssertThrowsError(try WorkoutMirroringCodec.decode(data)) { error in
            XCTAssertEqual(error as? WorkoutMirroringCodec.CodecError, .unsupportedVersion(99))
        }
    }

    func testRejectsMalformedPayload() {
        XCTAssertThrowsError(try WorkoutMirroringCodec.decode(Data("not json".utf8))) { error in
            XCTAssertEqual(error as? WorkoutMirroringCodec.CodecError, .malformedPayload)
        }
        let unknownMessage = Data(#"{"version":1,"message":{"teleport":{}}}"#.utf8)
        XCTAssertThrowsError(try WorkoutMirroringCodec.decode(unknownMessage)) { error in
            XCTAssertEqual(error as? WorkoutMirroringCodec.CodecError, .malformedPayload)
        }
    }

    func testConfigurationRequestCodable() throws {
        let request = WorkoutConfigurationRequest(activity: .running, location: .outdoor)
        let decoded = try JSONDecoder().decode(WorkoutConfigurationRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
    }
}
