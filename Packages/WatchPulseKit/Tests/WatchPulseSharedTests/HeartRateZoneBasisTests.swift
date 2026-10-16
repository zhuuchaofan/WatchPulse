import XCTest
@testable import WatchPulseShared

final class HeartRateZoneBasisTests: XCTestCase {
    private let workout = Fixture.workout(1, minutes: 10)

    private func points(_ values: [(TimeInterval, Double)]) -> [HeartRatePoint] {
        values.map { HeartRatePoint(date: workout.startDate.addingTimeInterval($0.0), beatsPerMinute: $0.1) }
    }

    private func settings(max: Int = 190) throws -> HeartRateZoneSettings {
        try HeartRateZoneSettings.percentOfMaximum(max) // 95 / 114 / 133 / 152 / 171
    }

    func testPersonalDistributionUsesConfiguredZonesAndTagsBasis() throws {
        let personal = try settings()
        // 每个样本代表之后 10 秒。
        let samples = points([(0, 100), (10, 120), (20, 140), (30, 160), (40, 180), (50, 180)])
        let distribution = HeartRateZoneAnalyzer.personal(points: samples, settings: personal)
        XCTAssertEqual(distribution.basis.kind, .personal)
        XCTAssertEqual(distribution.basis.maximumHeartRate, 190)
        XCTAssertEqual(distribution.basis.maximumSource, .userEntered)
        XCTAssertEqual(distribution.basis.lowerBounds, personal.lowerBounds)
        XCTAssertEqual(distribution.durations[1], 10) // 100 → Z1
        XCTAssertEqual(distribution.durations[2], 10) // 120 → Z2
        XCTAssertEqual(distribution.durations[3], 10)
        XCTAssertEqual(distribution.durations[4], 10)
        XCTAssertEqual(distribution.durations[5], 10) // 180 → Z5（最后一个样本没有后继，不计）
        XCTAssertEqual(distribution.coveredDuration, 50)
    }

    func testBelowFirstZoneIsTrackedSeparately() throws {
        let samples = points([(0, 80), (10, 80), (20, 140)])
        let distribution = HeartRateZoneAnalyzer.personal(points: samples, settings: try settings())
        XCTAssertEqual(distribution.belowRangeDuration, 20)
        XCTAssertEqual(distribution.durations.values.reduce(0, +), 0)
        XCTAssertEqual(distribution.coveredDuration, 20)
    }

    func testGapsOverSixtySecondsAreExcluded() throws {
        let samples = points([(0, 140), (10, 140), (200, 140), (210, 140)])
        let distribution = HeartRateZoneAnalyzer.personal(points: samples, settings: try settings())
        XCTAssertEqual(distribution.coveredDuration, 20) // 10 + 10；中间 190 秒缺测
    }

    func testDifferentConfigurationsProduceDifferentDistributionsAndAreNotComparable() throws {
        let samples = points([(0, 150), (10, 150), (20, 150)])
        let a = HeartRateZoneAnalyzer.personal(points: samples, settings: try settings(max: 190))
        let b = HeartRateZoneAnalyzer.personal(points: samples, settings: try settings(max: 175))
        XCTAssertNotEqual(a.durations, b.durations, "同一心率在不同配置下落入不同区间")
        XCTAssertFalse(a.basis.isComparable(with: b.basis))
    }

    func testSameBoundariesFromDifferentMethodsAreComparable() throws {
        let percent = try settings()
        let custom = try HeartRateZoneSettings(method: .custom, maximumHeartRate: 190, lowerBounds: percent.lowerBounds)
        let a = HeartRateZoneBasis.personal(percent)
        let b = HeartRateZoneBasis.personal(custom)
        XCTAssertTrue(a.isComparable(with: b))
    }

    func testSessionRelativeIsNeverComparable() {
        let a = HeartRateZoneBasis.sessionRelative(observedMaximum: 170)
        let b = HeartRateZoneBasis.sessionRelative(observedMaximum: 170)
        XCTAssertFalse(a.isComparable(with: b), "本次相对区间以本次最高心率为参照，不可跨运动比较")
        XCTAssertFalse(a.isComparable(with: .personal(try! settings())))
    }

    func testSessionRelativeMaximumIsMarkedAsObservedNotAMaximumHeartRate() {
        let basis = HeartRateZoneBasis.sessionRelative(observedMaximum: 171.4)
        XCTAssertEqual(basis.kind, .sessionRelative)
        XCTAssertEqual(basis.maximumSource, .observedInWorkout)
        XCTAssertEqual(basis.maximumHeartRate, 171)
        XCTAssertFalse(basis.isUserConfirmedMaximum)
        XCTAssertTrue(basis.title.contains("本次"))
        XCTAssertFalse(basis.title.contains("最大心率"), "观测值不得称为最大心率")
        XCTAssertNil(basis.lowerBounds)
    }

    func testPersonalBasisIsUserConfirmed() throws {
        let basis = HeartRateZoneBasis.personal(try settings())
        XCTAssertTrue(basis.isUserConfirmedMaximum)
        XCTAssertTrue(basis.title.contains("个人"))
        XCTAssertTrue(basis.title.contains("用户输入"))
    }

    func testBasisRoundTripsThroughCodable() throws {
        let basis = HeartRateZoneBasis.personal(try settings())
        let data = try JSONEncoder().encode(basis)
        XCTAssertEqual(try JSONDecoder().decode(HeartRateZoneBasis.self, from: data), basis)
    }
}
