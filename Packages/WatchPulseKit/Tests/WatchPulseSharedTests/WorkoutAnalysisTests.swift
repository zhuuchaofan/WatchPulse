import XCTest
@testable import WatchPulseShared

final class WorkoutAnalysisTests: XCTestCase {
    private func build(
        _ records: [WorkoutRecord],
        heartRates: [UUID: WorkoutHeartRateSeries] = [:],
        origin: HealthDataOrigin = .healthKit,
        zones: HeartRateZoneSettings? = nil
    ) -> WorkoutAnalysisSet {
        WorkoutAnalysisBuilder.build(records: records, heartRates: heartRates, origin: origin, zoneSettings: zones)
    }

    private func associated(_ workout: WorkoutRecord) -> WorkoutHeartRateSeries {
        WorkoutHeartRateSeries(points: Fixture.heartRate(for: workout), attribution: .workoutAssociated)
    }

    // MARK: 数据完整度与降级

    func testCompleteOutdoorRideIsFullyEligible() throws {
        let ride = Fixture.workout(1)
        let set = build([ride], heartRates: [ride.id: associated(ride)])
        let record = try XCTUnwrap(set.records.first)
        XCTAssertTrue(record.eligibility.canDisplay)
        XCTAssertTrue(record.eligibility.canCountInStatistics)
        XCTAssertTrue(record.eligibility.canCompareProgress)
        XCTAssertEqual(record.completeness.distance, .present)
        XCTAssertEqual(record.completeness.heartRate, .present)
        XCTAssertTrue(record.eligibility.progressMetrics.isSuperset(of: [.duration, .distance, .averageSpeed, .averageHeartRate]))
        XCTAssertTrue(record.eligibility.blockers.isEmpty)
    }

    func testMissingDistanceDegradesOnlyDistanceMetrics() throws {
        let ride = Fixture.workout(1, distanceKm: nil)
        let set = build([ride], heartRates: [ride.id: associated(ride)])
        let record = try XCTUnwrap(set.records.first)
        XCTAssertEqual(record.completeness.distance, .missing, "骑行应有距离，缺失是数据缺口")
        XCTAssertTrue(record.eligibility.canCountInStatistics)
        XCTAssertTrue(record.eligibility.statisticsMetrics.contains(.duration))
        XCTAssertFalse(record.eligibility.statisticsMetrics.contains(.distance))
        XCTAssertFalse(record.eligibility.progressMetrics.contains(.distance))
        XCTAssertFalse(record.eligibility.progressMetrics.contains(.averageSpeed))
        XCTAssertTrue(record.eligibility.progressMetrics.contains(.duration))
    }

    func testNonDistanceActivityDistanceIsNotApplicableNotMissing() throws {
        let hiit = Fixture.workout(1, activity: .highIntensityIntervalTraining, location: .indoor, distanceKm: nil)
        let record = try XCTUnwrap(build([hiit]).records.first)
        XCTAssertEqual(record.completeness.distance, .notApplicable)
    }

    func testMissingHeartRateKeepsRecordCountableButNotForHeartRateMetrics() throws {
        let ride = Fixture.workout(1, average: nil)
        let record = try XCTUnwrap(build([ride]).records.first) // 没有读取心率
        XCTAssertEqual(record.completeness.heartRate, .missing)
        XCTAssertEqual(record.heartRate.usability, .unavailable)
        XCTAssertTrue(record.eligibility.canCountInStatistics)
        XCTAssertFalse(record.eligibility.statisticsMetrics.contains(.averageHeartRate))
        XCTAssertFalse(record.eligibility.progressMetrics.contains(.averageHeartRate))
        XCTAssertTrue(record.eligibility.progressMetrics.contains(.distance))
    }

    func testUnknownLocationBlocksProgressComparisonButNotStatistics() throws {
        let ride = Fixture.workout(1, location: .unknown)
        let record = try XCTUnwrap(build([ride]).records.first)
        XCTAssertFalse(record.completeness.locationKnown)
        XCTAssertTrue(record.eligibility.canCountInStatistics)
        XCTAssertFalse(record.eligibility.canCompareProgress)
        XCTAssertTrue(record.eligibility.blockers.contains(.locationUnknown))
    }

    func testInvalidTimeRangeIsDisplayedButNeverCounted() throws {
        let valid = Fixture.workout(1)
        let broken = WorkoutRecord(
            id: Fixture.uuid(2), activity: .running, location: .outdoor,
            startDate: Fixture.base.addingTimeInterval(500), endDate: Fixture.base, duration: 0, sourceName: "X"
        )
        let set = build([valid, broken])
        let record = try XCTUnwrap(set.records.first { $0.id == broken.id })
        XCTAssertTrue(record.eligibility.canDisplay)
        XCTAssertFalse(record.eligibility.canCountInStatistics)
        XCTAssertFalse(record.eligibility.canCompareProgress)
        XCTAssertTrue(record.eligibility.blockers.contains(.invalidTimeRange))
        XCTAssertFalse(record.completeness.hasValidTimeRange)
    }

    func testNaNDurationIsInvalid() throws {
        let record = WorkoutRecord(
            id: Fixture.uuid(3), activity: .running, location: .outdoor,
            startDate: Fixture.base, endDate: Fixture.base.addingTimeInterval(600), duration: .nan, sourceName: "X"
        )
        XCTAssertFalse(try XCTUnwrap(build([record]).records.first).completeness.hasValidTimeRange)
    }

    // MARK: 心率可信度进入资格

    func testAllSourcesHeartRateIsDisplayOnlyAndExcludedFromStatistics() throws {
        let ride = Fixture.workout(1)
        let series = WorkoutHeartRateSeries(points: Fixture.heartRate(for: ride), attribution: .timeRangeAllSources)
        let record = try XCTUnwrap(build([ride], heartRates: [ride.id: series]).records.first)
        XCTAssertEqual(record.heartRate.usability, .displayOnly)
        XCTAssertFalse(record.eligibility.statisticsMetrics.contains(.averageHeartRate))
        XCTAssertFalse(record.eligibility.progressMetrics.contains(.averageHeartRate))
        XCTAssertFalse(record.eligibility.progressMetrics.contains(.speedAtHeartRate))
        XCTAssertTrue(record.eligibility.canCompareProgress, "距离与时长仍可比较")
    }

    func testSameDeviceHeartRateAllowsStatisticsButNotPerformance() throws {
        let ride = Fixture.workout(1)
        let series = WorkoutHeartRateSeries(points: Fixture.heartRate(for: ride), attribution: .sameDevice)
        let record = try XCTUnwrap(build([ride], heartRates: [ride.id: series]).records.first)
        XCTAssertTrue(record.eligibility.statisticsMetrics.contains(.averageHeartRate))
        XCTAssertFalse(record.eligibility.progressMetrics.contains(.averageHeartRate))
    }

    func testLowCoverageHeartRateIsNotComparable() throws {
        let ride = Fixture.workout(1)
        let series = WorkoutHeartRateSeries(points: Fixture.heartRate(for: ride, to: 1_200), attribution: .workoutAssociated)
        let record = try XCTUnwrap(build([ride], heartRates: [ride.id: series]).records.first)
        XCTAssertFalse(record.eligibility.progressMetrics.contains(.averageHeartRate))
        XCTAssertTrue(record.heartRate.reasons.contains(.lowCoverage))
    }

    // MARK: 区间

    func testPersonalZonesOnlyWhenUserConfiguredThem() throws {
        let ride = Fixture.workout(1)
        let heartRates = [ride.id: associated(ride)]
        XCTAssertNil(try XCTUnwrap(build([ride], heartRates: heartRates).records.first).personalZones,
                     "没有用户确认的区间配置，不得推算最大心率生成个人区间")
        let settings = try HeartRateZoneSettings.percentOfMaximum(190)
        let record = try XCTUnwrap(build([ride], heartRates: heartRates, zones: settings).records.first)
        XCTAssertEqual(record.personalZones?.basis, .personal(settings))
        XCTAssertTrue(record.eligibility.progressMetrics.contains(.heartRateZoneDistribution))
    }

    func testZoneMetricNeedsComparableHeartRate() throws {
        let ride = Fixture.workout(1)
        let series = WorkoutHeartRateSeries(points: Fixture.heartRate(for: ride), attribution: .sameDevice)
        let record = try XCTUnwrap(build([ride], heartRates: [ride.id: series], zones: try .percentOfMaximum(190)).records.first)
        XCTAssertFalse(record.eligibility.progressMetrics.contains(.heartRateZoneDistribution))
    }

    // MARK: 去重进入资格

    func testSuspectedDuplicateIsDisplayedButNeverUsedForProgress() throws {
        let a = Fixture.workout(1)
        let b = Fixture.workout(2, start: 40, source: Fixture.thirdParty)
        let set = build([a, b])
        XCTAssertEqual(set.records.count, 2)
        XCTAssertEqual(set.suspectedExcludedFromTotals, 1)
        let counted = set.records.filter(\.eligibility.canCountInStatistics)
        XCTAssertEqual(counted.count, 1)
        XCTAssertTrue(set.records.allSatisfy { !$0.eligibility.canCompareProgress })
        XCTAssertTrue(set.records.allSatisfy { $0.eligibility.canDisplay })
        let excluded = try XCTUnwrap(set.records.first { !$0.eligibility.canCountInStatistics })
        XCTAssertTrue(excluded.eligibility.blockers.contains(.excludedAsSuspectedDuplicate))
        let kept = try XCTUnwrap(counted.first)
        XCTAssertTrue(kept.eligibility.blockers.contains(.suspectedDuplicate))
    }

    func testConfirmedDuplicatesMergeAndKeepMergedSources() throws {
        let a = Fixture.workout(1, source: WorkoutSourceInfo(name: "体能训练", bundleIdentifier: "com.apple.health.X", externalIdentifier: "E1"))
        let b = Fixture.workout(2, start: 3, source: WorkoutSourceInfo(name: "Strava", bundleIdentifier: "com.strava", externalIdentifier: "E1"))
        let set = build([a, b])
        XCTAssertEqual(set.records.count, 1)
        let record = try XCTUnwrap(set.records.first)
        XCTAssertEqual(record.mergedSources.map(\.name).sorted(), ["Strava"])
        XCTAssertTrue(record.eligibility.canCompareProgress, "确认重复合并后是一次确定的运动")
    }

    // MARK: 演示标识

    func testSimulatedOriginIsCarriedOnEveryRecord() {
        let set = build([Fixture.workout(1), Fixture.workout(2, start: 90_000)], origin: .simulated)
        XCTAssertTrue(set.origin.isSimulated)
        XCTAssertTrue(set.records.allSatisfy { $0.origin.isSimulated })
    }

    func testRecordsAreSortedNewestFirst() {
        let set = build([Fixture.workout(1, start: 0), Fixture.workout(2, start: 90_000), Fixture.workout(3, start: 45_000)])
        XCTAssertEqual(set.records.map(\.id), [Fixture.uuid(2), Fixture.uuid(3), Fixture.uuid(1)])
    }
}
