import XCTest
@testable import WatchPulseShared

final class WorkoutComparabilityTests: XCTestCase {
    private let ultra = WorkoutSourceInfo(
        name: "体能训练", bundleIdentifier: "com.apple.health.ABCD",
        deviceName: "Apple Watch", deviceModel: "Watch", deviceHardwareVersion: "Watch7,5"
    )

    private func analysis(_ workout: WorkoutRecord, heartRate: HeartRateAttribution? = .workoutAssociated) -> WorkoutAnalysisRecord {
        let series = heartRate.map { WorkoutHeartRateSeries(points: Fixture.heartRate(for: workout), attribution: $0) }
        let set = WorkoutAnalysisBuilder.build(
            records: [workout], heartRates: series.map { [workout.id: $0] } ?? [:], origin: .healthKit, zoneSettings: nil
        )
        return set.records[0]
    }

    func testSimilarRidesFromSameSourceAndDeviceAreComparable() {
        let a = analysis(Fixture.workout(1, start: 0))
        let b = analysis(Fixture.workout(2, start: 86_400, minutes: 55, distanceKm: 19))
        guard case .comparable(let metrics, _) = WorkoutComparability.compare(a, b) else { return XCTFail("应可比较") }
        XCTAssertTrue(metrics.isSuperset(of: [.duration, .distance, .averageSpeed, .averageHeartRate]))
    }

    func testDifferentActivityIsNotComparable() {
        let ride = analysis(Fixture.workout(1))
        let run = analysis(Fixture.workout(2, activity: .running, start: 86_400, distanceKm: 8))
        XCTAssertEqual(WorkoutComparability.compare(ride, run), .notComparable([.differentActivity]))
    }

    func testIndoorVersusOutdoorIsNotComparable() {
        let outdoor = analysis(Fixture.workout(1))
        let indoor = analysis(Fixture.workout(2, location: .indoor, start: 86_400))
        XCTAssertEqual(WorkoutComparability.compare(outdoor, indoor), .notComparable([.differentLocation]))
    }

    func testUnknownLocationIsNotEligible() {
        let known = analysis(Fixture.workout(1))
        let unknown = analysis(Fixture.workout(2, location: .unknown, start: 86_400))
        guard case .notComparable(let reasons) = WorkoutComparability.compare(known, unknown) else { return XCTFail() }
        XCTAssertTrue(reasons.contains(.notEligible))
    }

    func testSourceChangeIsNotComparable() {
        let native = analysis(Fixture.workout(1))
        let other = analysis(Fixture.workout(2, start: 86_400, source: Fixture.thirdParty))
        guard case .notComparable(let reasons) = WorkoutComparability.compare(native, other) else { return XCTFail() }
        XCTAssertTrue(reasons.contains(.differentSource))
    }

    func testDeviceChangeWithinSameSourceIsNotComparable() {
        let series6 = analysis(Fixture.workout(1))
        let newer = analysis(Fixture.workout(2, start: 86_400, source: ultra))
        guard case .notComparable(let reasons) = WorkoutComparability.compare(series6, newer) else { return XCTFail() }
        XCTAssertEqual(reasons, [.differentDevice])
    }

    func testOneSideDeviceUnknownIsNotComparable() {
        let known = analysis(Fixture.workout(1))
        let noDevice = WorkoutSourceInfo(name: "体能训练", bundleIdentifier: "com.apple.health.ABCD")
        let unknown = analysis(Fixture.workout(2, start: 86_400, source: noDevice))
        guard case .notComparable(let reasons) = WorkoutComparability.compare(known, unknown) else { return XCTFail() }
        XCTAssertEqual(reasons, [.deviceUnknown])
    }

    func testBothDevicesUnknownSameSourceIsComparableWithCaveat() {
        let source = WorkoutSourceInfo(name: "第三方", bundleIdentifier: "com.example.fit")
        let a = analysis(Fixture.workout(1, source: source), heartRate: nil)
        let b = analysis(Fixture.workout(2, start: 86_400, source: source), heartRate: nil)
        guard case .comparable(_, let caveats) = WorkoutComparability.compare(a, b) else { return XCTFail("应可比较") }
        XCTAssertEqual(caveats, [.deviceNotRecorded])
    }

    func testVeryDifferentDistanceIsNotComparable() {
        let short = analysis(Fixture.workout(1, minutes: 60, distanceKm: 10))
        let long = analysis(Fixture.workout(2, start: 86_400, minutes: 60, distanceKm: 30))
        XCTAssertEqual(WorkoutComparability.compare(short, long), .notComparable([.distanceMismatch]))
    }

    func testVeryDifferentDurationWithoutDistanceIsNotComparable() {
        let a = analysis(Fixture.workout(1, activity: .highIntensityIntervalTraining, location: .indoor, minutes: 20, distanceKm: nil))
        let b = analysis(Fixture.workout(2, activity: .highIntensityIntervalTraining, location: .indoor, start: 86_400, minutes: 60, distanceKm: nil))
        XCTAssertEqual(WorkoutComparability.compare(a, b), .notComparable([.durationMismatch]))
    }

    func testHeartRateMetricsDroppedWhenOneSideIsNotComparable() {
        let good = analysis(Fixture.workout(1))
        let weak = analysis(Fixture.workout(2, start: 86_400), heartRate: .timeRangeAllSources)
        guard case .comparable(let metrics, _) = WorkoutComparability.compare(good, weak) else { return XCTFail() }
        XCTAssertFalse(metrics.contains(.averageHeartRate))
        XCTAssertTrue(metrics.contains(.distance))
    }

    func testZoneDistributionNeedsIdenticalPersonalBasis() throws {
        let a = Fixture.workout(1), b = Fixture.workout(2, start: 86_400)
        func record(_ workout: WorkoutRecord, max: Int) throws -> WorkoutAnalysisRecord {
            let series = WorkoutHeartRateSeries(points: Fixture.heartRate(for: workout), attribution: .workoutAssociated)
            return WorkoutAnalysisBuilder.build(
                records: [workout], heartRates: [workout.id: series], origin: .healthKit,
                zoneSettings: try .percentOfMaximum(max)
            ).records[0]
        }
        guard case .comparable(let same, _) = WorkoutComparability.compare(try record(a, max: 190), try record(b, max: 190)) else { return XCTFail() }
        XCTAssertTrue(same.contains(.heartRateZoneDistribution))
        guard case .comparable(let changed, _) = WorkoutComparability.compare(try record(a, max: 190), try record(b, max: 180)) else { return XCTFail() }
        XCTAssertFalse(changed.contains(.heartRateZoneDistribution), "区间配置变化后不可比较区间分布")
        XCTAssertTrue(changed.contains(.distance))
    }

    func testSuspectedDuplicateIsNotComparable() {
        let set = WorkoutAnalysisBuilder.build(
            records: [Fixture.workout(1), Fixture.workout(2, start: 40, source: Fixture.thirdParty), Fixture.workout(3, start: 86_400)],
            heartRates: [:], origin: .healthKit, zoneSettings: nil
        )
        let suspected = set.records.first { $0.id == Fixture.uuid(1) }!
        let other = set.records.first { $0.id == Fixture.uuid(3) }!
        guard case .notComparable(let reasons) = WorkoutComparability.compare(suspected, other) else { return XCTFail() }
        XCTAssertTrue(reasons.contains(.notEligible))
    }

    func testComparableWorkoutsFiltersAndSortsNewestFirst() {
        let target = analysis(Fixture.workout(1, start: 10 * 86_400))
        let candidates = [
            analysis(Fixture.workout(2, start: 0)),
            analysis(Fixture.workout(3, activity: .running, start: 86_400, distanceKm: 8)),
            analysis(Fixture.workout(4, start: 5 * 86_400)),
            analysis(Fixture.workout(5, start: 6 * 86_400, source: Fixture.thirdParty)),
            target,
        ]
        let result = WorkoutComparability.comparableWorkouts(to: target, in: candidates)
        XCTAssertEqual(result.map(\.id), [Fixture.uuid(4), Fixture.uuid(2)])
        XCTAssertFalse(result.contains { $0.id == target.id })
    }

    func testComparableWorkoutsExcludesFutureRelativeToTargetOnlyWhenRequested() {
        let target = analysis(Fixture.workout(1, start: 0))
        let later = analysis(Fixture.workout(2, start: 5 * 86_400))
        XCTAssertEqual(WorkoutComparability.comparableWorkouts(to: target, in: [later]).count, 1)
        XCTAssertEqual(WorkoutComparability.comparableWorkouts(to: target, in: [later], onlyBefore: true).count, 0)
    }
}
