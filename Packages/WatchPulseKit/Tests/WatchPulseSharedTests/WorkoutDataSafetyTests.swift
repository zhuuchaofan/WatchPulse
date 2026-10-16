import XCTest
@testable import WatchPulseShared

/// 数据安全不变式：去重只做分组 / 标注，不丢记录、不合并真实的独立运动；
/// 不可靠的心率归属不会产生任何“强结论”资格。
final class WorkoutDataSafetyTests: XCTestCase {
    // MARK: 不丢记录

    func testEveryInputRecordSurvivesDeduplication() {
        var generator = SeededGenerator(seed: 42)
        let sources = [Fixture.watch, Fixture.thirdParty, WorkoutSourceInfo(name: "Other", bundleIdentifier: "com.other")]
        let activities: [WorkoutActivityKind] = [.cycling, .running, .walking]
        for round in 0..<200 {
            let records = (1...12).map { n in
                Fixture.workout(
                    round * 100 + n,
                    activity: activities.randomElement(using: &generator)!,
                    location: [.indoor, .outdoor, .unknown].randomElement(using: &generator)!,
                    start: Double(Int.random(in: 0...6, using: &generator)) * 900,
                    minutes: Double(Int.random(in: 20...60, using: &generator)),
                    distanceKm: Bool.random(using: &generator) ? Double(Int.random(in: 5...30, using: &generator)) : nil,
                    source: sources.randomElement(using: &generator)!
                )
            }
            let result = WorkoutDeduplicator.deduplicate(records)
            let surviving = result.entries.flatMap { [$0.primary.id] + $0.mergedDuplicates.map(\.id) }
            XCTAssertEqual(Set(surviving), Set(records.map(\.id)), "原始记录一个都不能少")
            XCTAssertEqual(surviving.count, records.count, "也不能重复出现")
            XCTAssertGreaterThanOrEqual(result.entries.filter(\.countsTowardTotals).count, 1)
        }
    }

    func testDeduplicationDoesNotMutateRecords() {
        let records = [Fixture.workout(1), Fixture.workout(2, start: 40, source: Fixture.thirdParty)]
        let result = WorkoutDeduplicator.deduplicate(records)
        for entry in result.entries {
            XCTAssertTrue(records.contains(entry.primary), "主记录必须与 HealthKit 读到的记录逐字段相同")
        }
    }

    // MARK: 不误合并真实运动

    func testRealisticDayOfSeparateWorkoutsStaysSeparate() {
        let morningRun = Fixture.workout(1, activity: .running, start: 0, minutes: 40, distanceKm: 7)
        let commuteRide = Fixture.workout(2, activity: .cycling, start: 4 * 3_600, minutes: 25, distanceKm: 8)
        let eveningRideImported = Fixture.workout(3, activity: .cycling, start: 9 * 3_600, minutes: 60, distanceKm: 22, source: Fixture.thirdParty)
        // 骑行结束后 2 分钟开始的步行（同一来源、不同类型）。
        let cooldownWalk = Fixture.workout(4, activity: .walking, start: 9 * 3_600 + 62 * 60, minutes: 10, distanceKm: 0.8, source: Fixture.thirdParty)
        // 同一来源、同类型、连续两段（间隔 2 分钟）。
        let intervalA = Fixture.workout(5, activity: .running, start: 20 * 3_600, minutes: 20, distanceKm: 4)
        let intervalB = Fixture.workout(6, activity: .running, start: 20 * 3_600 + 22 * 60, minutes: 20, distanceKm: 4)
        // 不同来源、同类型、紧邻但不重叠（Watch 记 A，导入的是另一段）。
        let split = Fixture.workout(7, activity: .running, start: 20 * 3_600 + 44 * 60, minutes: 20, distanceKm: 4, source: Fixture.thirdParty)

        let all = [morningRun, commuteRide, eveningRideImported, cooldownWalk, intervalA, intervalB, split]
        let result = WorkoutDeduplicator.deduplicate(all)
        XCTAssertEqual(result.entries.count, all.count)
        XCTAssertTrue(result.entries.allSatisfy { $0.duplicateStatus == .unique && $0.countsTowardTotals })
    }

    func testSameWindowDifferentActivitiesAreNeverMerged() {
        for other in [WorkoutActivityKind.running, .walking, .highIntensityIntervalTraining, .other] {
            let ride = Fixture.workout(1)
            let twin = Fixture.workout(2, activity: other, source: Fixture.thirdParty)
            XCTAssertEqual(WorkoutDuplicateDetector.relation(ride, twin), .independent)
        }
    }

    // MARK: 不可靠心率不产生强结论

    func testHeartRateMetricsOnlyEverAppearForExactAndWellCoveredData() {
        let workout = Fixture.workout(1, minutes: 60)
        let attributions: [HeartRateAttribution] = [.workoutAssociated, .sameDevice, .timeRangeAllSources]
        let spans: [TimeInterval] = [600, 1_800, 2_520, 2_880, 3_600] // 覆盖 ≈17% … 100%
        let intervals: [TimeInterval] = [5, 30, 90]
        let strongMetrics: Set<WorkoutMetric> = [.averageHeartRate, .speedAtHeartRate, .heartRateZoneDistribution]
        let settings = try! HeartRateZoneSettings.percentOfMaximum(190)

        for attribution in attributions {
            for span in spans {
                for interval in intervals {
                    let series = WorkoutHeartRateSeries(
                        points: Fixture.heartRate(for: workout, interval: interval, to: span), attribution: attribution
                    )
                    let record = WorkoutAnalysisBuilder.build(
                        records: [workout], heartRates: [workout.id: series], origin: .healthKit, zoneSettings: settings
                    ).records[0]
                    let strong = record.eligibility.progressMetrics.intersection(strongMetrics)
                    if !strong.isEmpty {
                        XCTAssertEqual(attribution, .workoutAssociated, "\(attribution) 不得产生强结论")
                        XCTAssertGreaterThanOrEqual(record.heartRate.coverage, 0.8)
                        XCTAssertEqual(record.heartRate.usability, .comparable)
                    }
                    // 汇总统计同样不得使用仅可展示的数据。
                    if record.eligibility.statisticsMetrics.contains(.averageHeartRate) {
                        XCTAssertNotEqual(attribution, .timeRangeAllSources)
                        XCTAssertGreaterThanOrEqual(record.heartRate.coverage, 0.6)
                    }
                }
            }
        }
    }

    func testComparisonNeverIncludesHeartRateMetricsWhenEitherSideIsUnreliable() {
        let good = Fixture.workout(1), weak = Fixture.workout(2, start: 86_400)
        let goodSeries = WorkoutHeartRateSeries(points: Fixture.heartRate(for: good), attribution: .workoutAssociated)
        for attribution in [HeartRateAttribution.sameDevice, .timeRangeAllSources] {
            let weakSeries = WorkoutHeartRateSeries(points: Fixture.heartRate(for: weak), attribution: attribution)
            let set = WorkoutAnalysisBuilder.build(
                records: [good, weak], heartRates: [good.id: goodSeries, weak.id: weakSeries], origin: .healthKit, zoneSettings: nil
            )
            guard case .comparable(let metrics, _) = WorkoutComparability.compare(set.records[1], set.records[0]) else {
                return XCTFail("时长 / 距离仍可比较")
            }
            XCTAssertTrue(metrics.isDisjoint(with: [.averageHeartRate, .speedAtHeartRate, .heartRateZoneDistribution]))
        }
    }
}
