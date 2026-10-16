import XCTest
@testable import WatchPulseShared

final class HeartRateEvidenceTests: XCTestCase {
    private let workout = Fixture.workout(1, minutes: 60)

    private func series(_ points: [HeartRatePoint], _ attribution: HeartRateAttribution) -> WorkoutHeartRateSeries {
        WorkoutHeartRateSeries(points: points, attribution: attribution)
    }

    func testAssociatedFullCoverageIsComparable() {
        let evidence = HeartRateEvidence.evaluate(series(Fixture.heartRate(for: workout), .workoutAssociated), for: workout)
        XCTAssertEqual(evidence.usability, .comparable)
        XCTAssertEqual(evidence.coverage, 1, accuracy: 0.01)
        XCTAssertTrue(evidence.reasons.isEmpty)
        XCTAssertNotNil(evidence.statistics)
    }

    func testAllSourcesTimeRangeIsDisplayOnlyEvenWithPerfectCoverage() {
        let evidence = HeartRateEvidence.evaluate(series(Fixture.heartRate(for: workout), .timeRangeAllSources), for: workout)
        XCTAssertEqual(evidence.usability, .displayOnly)
        XCTAssertTrue(evidence.reasons.contains(.attributionAllSources))
        XCTAssertFalse(evidence.usability.allowsStatistics)
        XCTAssertFalse(evidence.usability.allowsPerformanceConclusions)
    }

    func testSameDeviceIsSummaryOnlyAndLabelled() {
        let evidence = HeartRateEvidence.evaluate(series(Fixture.heartRate(for: workout), .sameDevice), for: workout)
        XCTAssertEqual(evidence.usability, .summary)
        XCTAssertTrue(evidence.reasons.contains(.attributionSameDeviceTimeRange))
        XCTAssertTrue(evidence.usability.allowsStatistics)
        XCTAssertFalse(evidence.usability.allowsPerformanceConclusions)
    }

    func testSameDeviceCanBeOptedIntoComparison() {
        var configuration = HeartRateEvidenceConfiguration()
        configuration.allowSameDeviceForComparison = true
        let evidence = HeartRateEvidence.evaluate(series(Fixture.heartRate(for: workout), .sameDevice), for: workout, configuration: configuration)
        XCTAssertEqual(evidence.usability, .comparable)
    }

    func testHalfCoverageIsDisplayOnly() {
        // 前 30 分钟有数据，后 30 分钟缺测。
        let points = Fixture.heartRate(for: workout, to: 1_800)
        let evidence = HeartRateEvidence.evaluate(series(points, .workoutAssociated), for: workout)
        XCTAssertEqual(evidence.coverage, 0.5, accuracy: 0.01)
        XCTAssertEqual(evidence.usability, .displayOnly)
        XCTAssertTrue(evidence.reasons.contains(.lowCoverage))
    }

    func testSeventyPercentCoverageIsSummaryNotComparable() {
        let points = Fixture.heartRate(for: workout, to: 2_520) // 42 / 60 分钟
        let evidence = HeartRateEvidence.evaluate(series(points, .workoutAssociated), for: workout)
        XCTAssertEqual(evidence.coverage, 0.7, accuracy: 0.01)
        XCTAssertEqual(evidence.usability, .summary)
        XCTAssertTrue(evidence.reasons.contains(.partialCoverage))
    }

    func testSamplingGapsOverSixtySecondsCountAsMissing() {
        // 每 120 秒一个样本：任何间隔都超过 60 秒，覆盖率为 0。
        let points = Fixture.heartRate(for: workout, interval: 120)
        let evidence = HeartRateEvidence.evaluate(series(points, .workoutAssociated), for: workout)
        XCTAssertEqual(evidence.coverage, 0, accuracy: 0.001)
        XCTAssertEqual(evidence.usability, .displayOnly)
    }

    func testTooFewSamplesAreDisplayOnly() {
        let short = Fixture.workout(2, minutes: 1, distanceKm: nil)
        let points = (0..<6).map { HeartRatePoint(date: short.startDate.addingTimeInterval(Double($0) * 10), beatsPerMinute: 130) }
        let evidence = HeartRateEvidence.evaluate(series(points, .workoutAssociated), for: short)
        XCTAssertEqual(evidence.validSampleCount, 6)
        XCTAssertEqual(evidence.usability, .displayOnly)
        XCTAssertTrue(evidence.reasons.contains(.tooFewSamples))
    }

    func testEmptySeriesIsUnavailable() {
        let evidence = HeartRateEvidence.evaluate(series([], .workoutAssociated), for: workout)
        XCTAssertEqual(evidence.usability, .unavailable)
        XCTAssertNil(evidence.statistics)
        XCTAssertTrue(evidence.reasons.contains(.noSamples))
    }

    func testMissingSeriesIsUnavailable() {
        let evidence = HeartRateEvidence.evaluate(nil, for: workout)
        XCTAssertEqual(evidence.usability, .unavailable)
    }

    // MARK: 异常样本

    func testImplausibleAndNonFiniteSamplesAreExcludedAndCounted() {
        var points = Fixture.heartRate(for: workout)
        let injected: [Double] = [0, 12, 260, .nan, .infinity]
        for (index, value) in injected.enumerated() {
            points[index * 3] = HeartRatePoint(date: points[index * 3].date, beatsPerMinute: value)
        }
        let evidence = HeartRateEvidence.evaluate(series(points, .workoutAssociated), for: workout)
        XCTAssertEqual(evidence.anomalousSampleCount, 5)
        XCTAssertEqual(evidence.validSampleCount, points.count - 5)
        XCTAssertEqual(evidence.statistics?.maximum ?? 0, 140, accuracy: 0.001, "异常值不能污染统计")
        XCTAssertEqual(evidence.usability, .comparable, "占比 < 5% 仍可比较")
    }

    func testManyAnomaliesDowngradeToDisplayOnly() {
        var points = Fixture.heartRate(for: workout)
        for index in stride(from: 0, to: points.count, by: 5) { // 20% 异常
            points[index] = HeartRatePoint(date: points[index].date, beatsPerMinute: 0)
        }
        let evidence = HeartRateEvidence.evaluate(series(points, .workoutAssociated), for: workout)
        XCTAssertEqual(evidence.usability, .displayOnly)
        XCTAssertTrue(evidence.reasons.contains(.manyAnomalies))
    }

    func testModerateAnomaliesDowngradeComparableToSummary() {
        var points = Fixture.heartRate(for: workout)
        for index in stride(from: 0, to: points.count, by: 13) { // ≈ 7.7%
            points[index] = HeartRatePoint(date: points[index].date, beatsPerMinute: 0)
        }
        let evidence = HeartRateEvidence.evaluate(series(points, .workoutAssociated), for: workout)
        XCTAssertEqual(evidence.usability, .summary)
    }

    func testSamplesOutsideWorkoutWindowAreExcluded() {
        var points = Fixture.heartRate(for: workout)
        points.append(HeartRatePoint(date: workout.startDate.addingTimeInterval(-600), beatsPerMinute: 150))
        points.append(HeartRatePoint(date: workout.endDate.addingTimeInterval(600), beatsPerMinute: 150))
        let evidence = HeartRateEvidence.evaluate(series(points, .workoutAssociated), for: workout)
        XCTAssertEqual(evidence.anomalousSampleCount, 2)
        XCTAssertEqual(evidence.validSampleCount, points.count - 2)
    }

    func testDuplicateTimestampsAreAnomalous() {
        var points = Fixture.heartRate(for: workout)
        points.append(points[10])
        let evidence = HeartRateEvidence.evaluate(series(points, .workoutAssociated), for: workout)
        XCTAssertEqual(evidence.anomalousSampleCount, 1)
    }

    func testUnsortedInputGivesSameResult() {
        let points = Fixture.heartRate(for: workout)
        var generator = SeededGenerator(seed: 3)
        let a = HeartRateEvidence.evaluate(series(points, .workoutAssociated), for: workout)
        let b = HeartRateEvidence.evaluate(series(points.shuffled(using: &generator), .workoutAssociated), for: workout)
        XCTAssertEqual(a, b)
    }

    func testUsabilityOrdering() {
        XCTAssertTrue(HeartRateUsability.unavailable < .displayOnly)
        XCTAssertTrue(HeartRateUsability.displayOnly < .summary)
        XCTAssertTrue(HeartRateUsability.summary < .comparable)
    }
}
