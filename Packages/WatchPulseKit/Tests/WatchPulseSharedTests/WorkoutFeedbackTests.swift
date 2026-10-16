import XCTest
@testable import WatchPulseShared

final class WorkoutFeedbackTests: XCTestCase {
    private let day: TimeInterval = 86_400

    /// 用默认心率曲线（与运动关联）构建分析集合。`bpm` 为每条运动的心率；未列出的用 140。
    private func analyse(
        _ workouts: [WorkoutRecord],
        bpm: [Int: Double] = [:],
        attribution: [Int: HeartRateAttribution] = [:],
        zones: HeartRateZoneSettings? = nil
    ) -> WorkoutAnalysisSet {
        var series: [UUID: WorkoutHeartRateSeries] = [:]
        for workout in workouts {
            let key = Int(workout.id.uuidString.suffix(12))!
            series[workout.id] = WorkoutHeartRateSeries(
                points: Fixture.heartRate(for: workout, bpm: bpm[key] ?? 140),
                attribution: attribution[key] ?? .workoutAssociated
            )
        }
        return WorkoutAnalysisBuilder.build(records: workouts, heartRates: series, origin: .healthKit, zoneSettings: zones)
    }

    private func feedback(
        target: Int,
        in set: WorkoutAnalysisSet,
        configuration: WorkoutFeedbackConfiguration = .init()
    ) -> WorkoutFeedback {
        let record = set.record(containing: Fixture.uuid(target))!
        return WorkoutFeedbackCalculator.feedback(for: record, among: set.records, configuration: configuration)
    }

    /// 第 10 天的骑行（66 分钟、22 公里），以及之前 4 次相近的骑行（60 分钟、20 公里）。
    private func standardRides() -> [WorkoutRecord] {
        [Fixture.workout(10, start: 10 * day, minutes: 66, distanceKm: 22)]
            + (1...4).map { Fixture.workout($0, start: Double($0) * day) }
    }

    private func compared(_ item: WorkoutMetricFeedback?) -> (average: Double, difference: Double, relative: Double, direction: WorkoutFeedbackDirection, baseline: WorkoutFeedbackBaseline)? {
        guard case .compared(let average, let difference, let relative, let direction, let baseline)? = item?.outcome else { return nil }
        return (average, difference, relative, direction, baseline)
    }

    func testComparesEachMetricWithRecentComparableWorkouts() throws {
        let result = feedback(target: 10, in: analyse(standardRides(), bpm: [10: 150]))

        XCTAssertEqual(result.status, .compared)
        XCTAssertEqual(result.comparableCount, 4)
        XCTAssertEqual(result.excludedCount, 0)
        XCTAssertEqual(result.metrics.map(\.metric), [.duration, .distance, .averageSpeed, .averageHeartRate])

        let distance = try XCTUnwrap(compared(result.metric(.distance)))
        XCTAssertEqual(distance.average, 20_000, accuracy: 0.001)
        XCTAssertEqual(distance.relative, 0.1, accuracy: 0.0001)
        XCTAssertEqual(distance.direction, .higher)
        XCTAssertEqual(distance.baseline.sampleCount, 4)
        XCTAssertEqual(distance.baseline.workoutIDs, [4, 3, 2, 1].map(Fixture.uuid), "按时间倒序")
        XCTAssertEqual(distance.baseline.earliestStart, Fixture.base.addingTimeInterval(day))

        XCTAssertEqual(compared(result.metric(.duration))?.direction, .higher)
        XCTAssertEqual(compared(result.metric(.averageSpeed))?.direction, .similar, "22 公里 / 66 分钟 与 20 公里 / 60 分钟 均速相同")
        let heartRate = try XCTUnwrap(compared(result.metric(.averageHeartRate)))
        XCTAssertEqual(heartRate.difference, 10, accuracy: 0.001)
        XCTAssertEqual(heartRate.direction, .higher)
    }

    func testTooFewComparableWorkoutsShowsOnlyThisWorkout() {
        let rides = [Fixture.workout(10, start: 10 * day)] + (1...2).map { Fixture.workout($0, start: Double($0) * day) }
        let result = feedback(target: 10, in: analyse(rides))

        XCTAssertEqual(result.status, .insufficientSamples(found: 2, required: 3))
        for item in result.metrics {
            XCTAssertEqual(item.outcome, .insufficientSamples(found: 2, required: 3), "\(item.metric)")
            XCTAssertNotNil(item.currentValue, "本次数据照常展示")
        }
        XCTAssertTrue(WorkoutFeedbackPresentation.headline(result).contains("只显示本次数据"))
    }

    func testOnlyEarlierWorkoutsInsideTheLookbackWindowAreUsed() {
        let rides = standardRides() + [
            Fixture.workout(20, start: 11 * day),            // 之后的运动
            Fixture.workout(21, start: 10 * day - 91 * day), // 超出 90 天
            Fixture.workout(22, activity: .running, start: 9 * day, distanceKm: 8),
        ]
        let result = feedback(target: 10, in: analyse(rides))
        XCTAssertEqual(result.comparableCount, 4)
        XCTAssertEqual(result.excludedCount, 0, "其他类型、窗口外的运动不算“未纳入”")
        XCTAssertEqual(compared(result.metric(.duration))?.baseline.workoutIDs, [4, 3, 2, 1].map(Fixture.uuid))
    }

    func testUsesAtMostTheMostRecentSamples() {
        let rides = [Fixture.workout(10, start: 10 * day)] + (1...7).map { Fixture.workout($0, start: Double($0) * day) }
        let result = feedback(target: 10, in: analyse(rides))
        XCTAssertEqual(result.comparableCount, 7)
        XCTAssertEqual(compared(result.metric(.distance))?.baseline.workoutIDs, [7, 6, 5, 4, 3].map(Fixture.uuid))
    }

    func testNonComparableWorkoutsAreCountedWithReasons() {
        let otherWatch = WorkoutSourceInfo(
            name: "体能训练", bundleIdentifier: "com.apple.health.ABCD",
            deviceName: "Apple Watch", deviceModel: "Watch", deviceHardwareVersion: "Watch7,5"
        )
        let rides = standardRides() + [
            Fixture.workout(30, location: .indoor, start: 5 * day),
            Fixture.workout(31, start: 6 * day, source: otherWatch),
            Fixture.workout(32, start: 7 * day, distanceKm: 60, average: 140),
        ]
        let result = feedback(target: 10, in: analyse(rides))

        XCTAssertEqual(result.comparableCount, 4)
        XCTAssertEqual(result.excludedCount, 3)
        XCTAssertEqual(Set(result.exclusions.map(\.reason)), [.differentLocation, .differentDevice, .distanceMismatch])
        let line = WorkoutFeedbackPresentation.exclusionLine(result)
        XCTAssertEqual(line?.hasPrefix("另有 3 次同类运动未纳入比较"), true)
    }

    func testIneligibleWorkoutIsNotCompared() {
        let rides = [Fixture.workout(10, location: .unknown, start: 10 * day)] + (1...4).map { Fixture.workout($0, start: Double($0) * day) }
        let result = feedback(target: 10, in: analyse(rides))

        XCTAssertEqual(result.status, .notEligible([.locationUnknown]))
        XCTAssertEqual(result.comparableCount, 0)
        XCTAssertTrue(result.metrics.allSatisfy { $0.outcome == .unavailable(.workoutNotEligible) })
        XCTAssertTrue(WorkoutFeedbackPresentation.headline(result).contains("没有记录是室内还是室外"))
    }

    func testDisplayOnlyHeartRateIsNotCompared() {
        let result = feedback(target: 10, in: analyse(standardRides(), attribution: [10: .timeRangeAllSources]))

        XCTAssertEqual(result.status, .compared)
        XCTAssertEqual(result.metric(.averageHeartRate)?.outcome, .unavailable(.heartRateNotComparable(.displayOnly)))
        XCTAssertNotNil(result.metric(.averageHeartRate)?.currentValue, "仍展示本次心率")
        XCTAssertNotNil(compared(result.metric(.distance)))
    }

    func testHeartRateComparisonUsesOnlyWorkoutsWithComparableHeartRate() {
        // 两次更早的运动心率仅可展示：心率只剩 2 个可比样本，其余指标仍有 4 个。
        let result = feedback(target: 10, in: analyse(standardRides(), attribution: [1: .timeRangeAllSources, 2: .timeRangeAllSources]))
        XCTAssertEqual(compared(result.metric(.distance))?.baseline.sampleCount, 4)
        XCTAssertEqual(result.metric(.averageHeartRate)?.outcome, .insufficientSamples(found: 2, required: 3))
    }

    func testActivityWithoutDistanceHasNoDistanceMetrics() {
        let sessions = [Fixture.workout(10, activity: .highIntensityIntervalTraining, location: .indoor, start: 10 * day, distanceKm: nil)]
            + (1...3).map { Fixture.workout($0, activity: .highIntensityIntervalTraining, location: .indoor, start: Double($0) * day, distanceKm: nil) }
        let result = feedback(target: 10, in: analyse(sessions))
        XCTAssertEqual(result.metrics.map(\.metric), [.duration, .averageHeartRate])
        XCTAssertEqual(result.status, .compared)
    }

    func testMissingDistanceIsShownAsNoDataNotZero() {
        let rides = [Fixture.workout(10, start: 10 * day, distanceKm: nil)] + (1...4).map { Fixture.workout($0, start: Double($0) * day) }
        let result = feedback(target: 10, in: analyse(rides))
        XCTAssertNil(result.metric(.distance)?.currentValue)
        XCTAssertEqual(result.metric(.distance)?.outcome, .unavailable(.noData))
        XCTAssertEqual(WorkoutFeedbackPresentation.format(nil, metric: .distance, activity: .cycling), "--")
    }

    func testResultDoesNotDependOnInputOrder() {
        let rides = standardRides() + [Fixture.workout(30, location: .indoor, start: 5 * day)]
        let a = feedback(target: 10, in: analyse(rides))
        let b = feedback(target: 10, in: analyse(rides.reversed()))
        XCTAssertEqual(a, b)
    }

    func testPersonalZoneDistributionIsComparedOnlyWithConfiguredZones() throws {
        let settings = try HeartRateZoneSettings.percentOfMaximum(190)
        let withZones = feedback(target: 10, in: analyse(standardRides(), bpm: [10: 160], zones: settings))
        guard case .compared(let baseline) = withZones.zones.outcome else { return XCTFail("应比较区间分布") }
        XCTAssertEqual(baseline.sampleCount, 4)
        XCTAssertEqual(withZones.zones.basis?.kind, .personal)
        // 160 次/分 → Z4（152–170）；140 次/分 → Z3（133–151）。
        let z4 = try XCTUnwrap(withZones.zones.rows.first { $0.zone == 4 })
        XCTAssertEqual(z4.currentShare, 1, accuracy: 0.001)
        XCTAssertEqual(z4.baselineShare ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(z4.direction, .higher)

        let withoutZones = feedback(target: 10, in: analyse(standardRides()))
        XCTAssertEqual(withoutZones.zones.outcome, .unavailable(.noPersonalZones))
        XCTAssertTrue(withoutZones.zones.rows.isEmpty)
    }

    func testMergedDuplicateResolvesToPrimaryRecord() {
        let phone = WorkoutSourceInfo(
            name: "WatchPulse", bundleIdentifier: "com.example.watchpulse",
            deviceName: "Apple Watch", deviceModel: "Watch", deviceHardwareVersion: "Watch6,1"
        )
        // 同一设备、不同来源、起止时间一致：确认重复，合并为一条。
        let copy = Fixture.workout(11, start: 10 * day, minutes: 66, distanceKm: 22, source: phone)
        let set = analyse(standardRides() + [copy])
        let record = set.record(containing: Fixture.uuid(11))
        XCTAssertNotNil(record)
        XCTAssertEqual(set.records.count, 5)
        XCTAssertTrue([Fixture.uuid(10), Fixture.uuid(11)].contains(record!.id))
    }

    func testPresentationDescribesComparisonWithEvidence() {
        let result = feedback(target: 10, in: analyse(standardRides(), bpm: [10: 150]))
        XCTAssertEqual(
            WorkoutFeedbackPresentation.comparison(result.metric(.distance)!, activity: .cycling),
            "比最近 4 次平均（20.00 公里）长 10%"
        )
        XCTAssertEqual(
            WorkoutFeedbackPresentation.comparison(result.metric(.averageHeartRate)!, activity: .cycling),
            "比最近 4 次平均（140 次/分）高 10 次/分"
        )
        XCTAssertEqual(
            WorkoutFeedbackPresentation.comparison(result.metric(.averageSpeed)!, activity: .cycling),
            "与最近 4 次平均（20.0 km/h）相近"
        )
        XCTAssertTrue(WorkoutFeedbackPresentation.headline(result).hasPrefix("与你之前 90 天内可比的室外骑行比较"))
        XCTAssertEqual(WorkoutFeedbackPresentation.pace(metersPerSecond: 1000.0 / 330), "5'30\" /公里")
    }

    func testFeedbackTextAvoidsJudgementalWording() {
        let result = feedback(target: 10, in: analyse(standardRides(), bpm: [10: 150]))
        let texts = [WorkoutFeedbackPresentation.headline(result), WorkoutFeedbackPresentation.disclaimer]
            + result.metrics.map { WorkoutFeedbackPresentation.comparison($0, activity: .cycling) }
        for text in texts {
            for word in ["进步了", "退步了", "更健康", "诊断", "恢复"] {
                XCTAssertFalse(text.contains(word), "“\(text)” 不应包含 “\(word)”")
            }
        }
    }
}
