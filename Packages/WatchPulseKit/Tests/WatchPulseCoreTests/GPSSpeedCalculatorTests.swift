import Foundation
import XCTest
import WatchPulseCore
import WatchPulseShared

final class GPSSpeedCalculatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func fix(_ offset: TimeInterval, speed: Double, speedAccuracy: Double = 0.5, horizontal: Double = 5) -> LocationFix {
        LocationFix(timestamp: t0.addingTimeInterval(offset), speed: speed, speedAccuracy: speedAccuracy, horizontalAccuracy: horizontal)
    }

    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    func testNoFixesIsUnavailableNotZero() {
        let calculator = GPSSpeedCalculator()
        let sample = calculator.sample(at: t0)
        XCTAssertEqual(sample.quality, .unavailable)
        XCTAssertNil(sample.metersPerSecond)
    }

    func testValidFixesAreSmoothed() {
        var calculator = GPSSpeedCalculator()
        XCTAssertEqual(calculator.ingest(fix(0, speed: 7), receivedAt: at(0)), .accepted)
        XCTAssertEqual(calculator.ingest(fix(1, speed: 8), receivedAt: at(1)), .accepted)
        XCTAssertEqual(calculator.ingest(fix(2, speed: 9), receivedAt: at(2)), .accepted)
        let sample = calculator.sample(at: at(2))
        XCTAssertEqual(sample.quality, .good)
        XCTAssertEqual(sample.source, .gps)
        XCTAssertEqual(sample.metersPerSecond ?? 0, 8, accuracy: 0.001)
        XCTAssertEqual(sample.sampleDate, at(2))
    }

    func testSmoothingWindowDropsOldFixes() {
        var calculator = GPSSpeedCalculator(configuration: .init(smoothingWindow: 3))
        for second in 0...10 {
            calculator.ingest(fix(TimeInterval(second), speed: second < 6 ? 5 : 6), receivedAt: at(TimeInterval(second)))
        }
        XCTAssertEqual(calculator.sample(at: at(10)).metersPerSecond ?? 0, 6, accuracy: 0.001)
    }

    func testNegativeSpeedIsInvalid() {
        var calculator = GPSSpeedCalculator()
        XCTAssertEqual(calculator.ingest(fix(0, speed: -1), receivedAt: at(0)), .rejected(.invalidSpeed))
        XCTAssertEqual(calculator.ingest(fix(1, speed: 5, speedAccuracy: -1), receivedAt: at(1)), .rejected(.invalidSpeed))
        XCTAssertEqual(calculator.ingest(fix(2, speed: 5, horizontal: -1), receivedAt: at(2)), .rejected(.poorAccuracy))
        XCTAssertEqual(calculator.sample(at: at(2)).quality, .unavailable)
    }

    func testPoorAccuracyRejectedAndMediocreAccuracyMarked() {
        var calculator = GPSSpeedCalculator()
        XCTAssertEqual(calculator.ingest(fix(0, speed: 5, horizontal: 80), receivedAt: at(0)), .rejected(.poorAccuracy))
        XCTAssertEqual(calculator.ingest(fix(1, speed: 5, speedAccuracy: 9), receivedAt: at(1)), .rejected(.poorAccuracy))
        XCTAssertEqual(calculator.ingest(fix(2, speed: 5, horizontal: 20), receivedAt: at(2)), .accepted)
        let sample = calculator.sample(at: at(2))
        XCTAssertEqual(sample.quality, .lowAccuracy)
        XCTAssertEqual(sample.metersPerSecond ?? 0, 5, accuracy: 0.001)
    }

    func testTrueStandstillShowsZero() {
        var calculator = GPSSpeedCalculator()
        calculator.ingest(fix(0, speed: 0), receivedAt: at(0))
        calculator.ingest(fix(1, speed: 0), receivedAt: at(1))
        let sample = calculator.sample(at: at(1))
        XCTAssertEqual(sample.quality, .good)
        XCTAssertEqual(sample.metersPerSecond, 0)
    }

    func testStaleAfterTimeoutShowsNoValue() {
        var calculator = GPSSpeedCalculator(configuration: .init(staleAfter: 5))
        calculator.ingest(fix(0, speed: 7), receivedAt: at(0))
        XCTAssertEqual(calculator.sample(at: at(4.9)).quality, .good)
        let stale = calculator.sample(at: at(5.1))
        XCTAssertEqual(stale.quality, .stale)
        XCTAssertNil(stale.metersPerSecond)
        XCTAssertEqual(stale.sampleDate, at(0))
    }

    func testTimestampGoingBackwardsIsRejected() {
        var calculator = GPSSpeedCalculator()
        calculator.ingest(fix(5, speed: 7), receivedAt: at(5))
        XCTAssertEqual(calculator.ingest(fix(3, speed: 9), receivedAt: at(6)), .rejected(.outOfOrder))
        XCTAssertEqual(calculator.ingest(fix(5, speed: 9), receivedAt: at(6)), .rejected(.outOfOrder))
    }

    func testOldFixDeliveredLateIsRejected() {
        var calculator = GPSSpeedCalculator(configuration: .init(maximumFixAge: 10))
        XCTAssertEqual(calculator.ingest(fix(0, speed: 7), receivedAt: at(30)), .rejected(.tooOld))
    }

    func testImplausibleSpeedAndSpikesAreFiltered() {
        var calculator = GPSSpeedCalculator()
        calculator.ingest(fix(0, speed: 7), receivedAt: at(0))
        XCTAssertEqual(calculator.ingest(fix(1, speed: 45), receivedAt: at(1)), .rejected(.implausibleSpeed))
        // 1 秒内从 7 m/s 跳到 20 m/s（13 m/s²）视为跳点。
        XCTAssertEqual(calculator.ingest(fix(2, speed: 20), receivedAt: at(2)), .rejected(.spike))
        XCTAssertEqual(calculator.sample(at: at(2)).metersPerSecond ?? 0, 7, accuracy: 0.001)
    }

    func testPersistentChangeIsEventuallyAccepted() {
        // 连续多次“跳点”说明速度确实变了（例如下坡），不能永久拒绝。
        var calculator = GPSSpeedCalculator(configuration: .init(spikeResetCount: 3))
        calculator.ingest(fix(0, speed: 3), receivedAt: at(0))
        XCTAssertEqual(calculator.ingest(fix(1, speed: 15), receivedAt: at(1)), .rejected(.spike))
        XCTAssertEqual(calculator.ingest(fix(1.5, speed: 15), receivedAt: at(1.5)), .rejected(.spike))
        XCTAssertEqual(calculator.ingest(fix(2, speed: 15), receivedAt: at(2)), .accepted)
        XCTAssertEqual(calculator.sample(at: at(2)).metersPerSecond ?? 0, 15, accuracy: 0.001)
    }

    func testPauseHidesSpeedAndResumeStartsFresh() {
        var calculator = GPSSpeedCalculator()
        calculator.ingest(fix(0, speed: 7), receivedAt: at(0))
        calculator.pause()
        XCTAssertEqual(calculator.sample(at: at(1)).quality, .paused)
        XCTAssertNil(calculator.sample(at: at(1)).metersPerSecond)
        XCTAssertEqual(calculator.ingest(fix(2, speed: 7), receivedAt: at(2)), .rejected(.paused))

        calculator.resume()
        // 暂停前的旧样本不参与平滑，也不会被当成“新鲜”数据。
        XCTAssertEqual(calculator.sample(at: at(3)).quality, .unavailable)
        calculator.ingest(fix(4, speed: 2), receivedAt: at(4))
        XCTAssertEqual(calculator.sample(at: at(4)).metersPerSecond ?? 0, 2, accuracy: 0.001)
    }

    func testResumeAfterPauseDoesNotTreatGapAsSpike() {
        var calculator = GPSSpeedCalculator()
        calculator.ingest(fix(0, speed: 2), receivedAt: at(0))
        calculator.pause()
        calculator.resume()
        XCTAssertEqual(calculator.ingest(fix(60, speed: 12), receivedAt: at(60)), .accepted)
    }

    func testGapAfterSignalLossDoesNotTreatNewSpeedAsSpike() {
        var calculator = GPSSpeedCalculator()
        calculator.ingest(fix(0, speed: 2), receivedAt: at(0))
        // 隧道中 30 秒无定位，出来时速度 10 m/s：间隔足够长，按 30 秒计算加速度，不算跳点。
        XCTAssertEqual(calculator.ingest(fix(30, speed: 10), receivedAt: at(30)), .accepted)
    }

    func testNotAuthorized() {
        var calculator = GPSSpeedCalculator()
        calculator.ingest(fix(0, speed: 7), receivedAt: at(0))
        calculator.authorization = .denied
        XCTAssertEqual(calculator.sample(at: at(0)).quality, .notAuthorized)
        XCTAssertNil(calculator.sample(at: at(0)).metersPerSecond)
    }

    func testRandomNoiseNeverProducesInvalidOutput() {
        var calculator = GPSSpeedCalculator()
        var generator = SeededRandomGenerator(seed: 7)
        var time: TimeInterval = 0
        for _ in 0..<5_000 {
            time += generator.value(in: -0.5...2)
            let speed = generator.value(in: -5...60)
            let fix = LocationFix(
                timestamp: t0.addingTimeInterval(time),
                speed: speed,
                speedAccuracy: generator.value(in: -1...10),
                horizontalAccuracy: generator.value(in: -1...120)
            )
            calculator.ingest(fix, receivedAt: t0.addingTimeInterval(time + generator.value(in: 0...3)))
            let sample = calculator.sample(at: t0.addingTimeInterval(time + 1))
            if let value = sample.metersPerSecond {
                XCTAssertTrue(value.isFinite)
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, GPSSpeedCalculator.Configuration().maximumPlausibleSpeed)
                XCTAssertTrue(sample.quality.hasValue)
            }
        }
    }
}
