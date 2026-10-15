import XCTest
@testable import WatchPulseShared

final class WorkoutDeduplicationTests: XCTestCase {
    // MARK: 确认重复

    func testSameHealthKitUUIDIsConfirmedDuplicate() {
        let a = Fixture.workout(1)
        let b = Fixture.workout(1)
        XCTAssertEqual(WorkoutDuplicateDetector.relation(a, b), .confirmed(.sameWorkoutIdentifier))
    }

    func testSameExternalIdentifierAcrossSourcesIsConfirmed() {
        let a = Fixture.workout(1, source: sourced(Fixture.watch, external: "EXT-1"))
        let b = Fixture.workout(2, start: 90, source: sourced(Fixture.thirdParty, external: "EXT-1"))
        XCTAssertEqual(WorkoutDuplicateDetector.relation(a, b), .confirmed(.sameExternalIdentifier))
    }

    func testEmptyExternalIdentifierIsNotAKey() {
        let a = Fixture.workout(1, source: sourced(Fixture.watch, external: ""))
        let b = Fixture.workout(2, source: sourced(Fixture.thirdParty, external: ""))
        XCTAssertNotEqual(WorkoutDuplicateDetector.relation(a, b), .confirmed(.sameExternalIdentifier))
    }

    func testSameDeviceDifferentSourceTightWindowIsConfirmed() {
        // 同一块手表上两个来源写入完全相同的窗口。
        let other = WorkoutSourceInfo(
            name: "第三方", bundleIdentifier: "com.example.fit",
            deviceName: "Apple Watch", deviceModel: "Watch", deviceHardwareVersion: "Watch6,1"
        )
        let a = Fixture.workout(1)
        let b = Fixture.workout(2, start: 1, source: other)
        XCTAssertEqual(WorkoutDuplicateDetector.relation(a, b), .confirmed(.sameDeviceSameWindow))
    }

    func testSameDeviceButWindowOffByTenSecondsIsOnlySuspected() {
        let other = WorkoutSourceInfo(
            name: "第三方", bundleIdentifier: "com.example.fit",
            deviceName: "Apple Watch", deviceModel: "Watch", deviceHardwareVersion: "Watch6,1"
        )
        let a = Fixture.workout(1)
        let b = Fixture.workout(2, start: 10, source: other)
        guard case .suspected = WorkoutDuplicateDetector.relation(a, b) else {
            return XCTFail("应为疑似重复")
        }
    }

    // MARK: 疑似重复

    func testCrossSourceSimilarWindowIsSuspectedNotConfirmed() {
        // 原生记录 + 第三方导入，起止相差 40 秒，距离相差 3%。
        let a = Fixture.workout(1)
        let b = Fixture.workout(2, start: 40, distanceKm: 20.6, source: Fixture.thirdParty)
        guard case .suspected = WorkoutDuplicateDetector.relation(a, b) else {
            return XCTFail("跨来源相似窗口应为疑似重复，不能直接确认")
        }
    }

    func testSuspectedWhenDistanceMissingOnOneSide() {
        let a = Fixture.workout(1)
        let b = Fixture.workout(2, start: 30, distanceKm: nil, source: Fixture.thirdParty)
        guard case .suspected = WorkoutDuplicateDetector.relation(a, b) else {
            return XCTFail("缺失距离不能作为否定证据")
        }
    }

    // MARK: 独立运动（不得误判）

    func testOverlapAndSameActivityAloneIsNotDuplicate_DifferentActivity() {
        let ride = Fixture.workout(1, activity: .cycling)
        let walk = Fixture.workout(2, activity: .walking, distanceKm: 3, source: Fixture.thirdParty)
        XCTAssertEqual(WorkoutDuplicateDetector.relation(ride, walk), .independent)
    }

    func testShortWorkoutInsideLongWorkoutIsIndependent() {
        let long = Fixture.workout(1, minutes: 120, distanceKm: 40)
        let short = Fixture.workout(2, start: 1_800, minutes: 20, distanceKm: 7, source: Fixture.thirdParty)
        XCTAssertEqual(WorkoutDuplicateDetector.relation(long, short), .independent)
    }

    func testSameSourceBackToBackWithSmallOverlapIsIndependent() {
        let first = Fixture.workout(1, minutes: 30)
        let second = Fixture.workout(2, start: 1_770, minutes: 30) // 重叠 30 秒
        XCTAssertEqual(WorkoutDuplicateDetector.relation(first, second), .independent)
    }

    func testSameSourceSameWindowWithoutIdentifierIsIndependent() {
        // 同来源两条记录，没有可靠标识：不能凭时间断定重复。
        let a = Fixture.workout(1)
        let b = Fixture.workout(2)
        XCTAssertEqual(WorkoutDuplicateDetector.relation(a, b), .independent)
    }

    func testConflictingDistancesAreIndependent() {
        let a = Fixture.workout(1, distanceKm: 20)
        let b = Fixture.workout(2, distanceKm: 10, source: Fixture.thirdParty)
        XCTAssertEqual(WorkoutDuplicateDetector.relation(a, b), .independent)
    }

    func testConflictingIndoorOutdoorIsIndependent() {
        let a = Fixture.workout(1, location: .indoor)
        let b = Fixture.workout(2, location: .outdoor, source: Fixture.thirdParty)
        XCTAssertEqual(WorkoutDuplicateDetector.relation(a, b), .independent)
    }

    func testUnknownLocationDoesNotBlockSuspicion() {
        let a = Fixture.workout(1, location: .unknown)
        let b = Fixture.workout(2, location: .outdoor, start: 20, source: Fixture.thirdParty)
        guard case .suspected = WorkoutDuplicateDetector.relation(a, b) else {
            return XCTFail("室内外未知不应阻止疑似判定")
        }
    }

    func testDifferentSourceIdentifiersMissingEntirely() {
        // 来源信息只有名称（无 bundle）也能比较；名称相同视为同来源。
        let a = WorkoutRecord(id: Fixture.uuid(1), activity: .running, location: .outdoor,
                              startDate: Fixture.base, endDate: Fixture.base.addingTimeInterval(1800),
                              duration: 1800, sourceName: "X")
        let b = WorkoutRecord(id: Fixture.uuid(2), activity: .running, location: .outdoor,
                              startDate: Fixture.base, endDate: Fixture.base.addingTimeInterval(1800),
                              duration: 1800, sourceName: "X")
        XCTAssertEqual(WorkoutDuplicateDetector.relation(a, b), .independent)
    }

    // MARK: 分组与统计处理

    func testConfirmedDuplicatesCollapseAndKeepProvenance() {
        let primary = Fixture.workout(1)
        let mirrored = Fixture.workout(2, start: 1, source: otherDeviceSource())
        let result = WorkoutDeduplicator.deduplicate([mirrored, primary])
        XCTAssertEqual(result.entries.count, 1)
        let entry = result.entries[0]
        XCTAssertEqual(entry.mergedDuplicates.count, 1)
        XCTAssertEqual(Set([entry.primary.id] + entry.mergedDuplicates.map(\.id)), [Fixture.uuid(1), Fixture.uuid(2)])
        XCTAssertTrue(entry.countsTowardTotals)
        XCTAssertEqual(entry.duplicateStatus, .confirmedMerged(count: 1))
    }

    func testPrimaryPrefersMoreCompleteRecord() {
        let sparse = Fixture.workout(1, distanceKm: nil, average: nil, source: sourced(Fixture.watch, external: "E"))
        let rich = Fixture.workout(2, source: sourced(Fixture.thirdParty, external: "E"))
        let result = WorkoutDeduplicator.deduplicate([sparse, rich])
        XCTAssertEqual(result.entries.first?.primary.id, Fixture.uuid(2))
    }

    func testSuspectedDuplicatesAreBothKeptAndCountedOnce() {
        let a = Fixture.workout(1)
        let b = Fixture.workout(2, start: 40, source: Fixture.thirdParty)
        let result = WorkoutDeduplicator.deduplicate([a, b])
        XCTAssertEqual(result.entries.count, 2, "疑似重复不能静默删除")
        XCTAssertEqual(result.entries.filter(\.countsTowardTotals).count, 1, "统计默认只计一次")
        XCTAssertEqual(result.suspectedExcludedFromTotals, 1)
        for entry in result.entries {
            guard case .suspected = entry.duplicateStatus else { return XCTFail("两条都应标注疑似重复") }
        }
    }

    func testSuspectedKeepsNativeAppleRecordAsCounted() {
        let native = Fixture.workout(1)
        let imported = Fixture.workout(2, start: 40, source: Fixture.thirdParty)
        let result = WorkoutDeduplicator.deduplicate([imported, native])
        let counted = result.entries.first { $0.countsTowardTotals }
        XCTAssertEqual(counted?.primary.id, Fixture.uuid(1))
    }

    func testSuspicionIsNotTransitive() {
        // A≈B（B 在 A 之后 4 分钟结束），B≈C，但 A 与 C 相差过大。
        let a = Fixture.workout(1, start: 0, minutes: 60, source: sourced(Fixture.watch, external: nil))
        let b = Fixture.workout(2, start: 240, minutes: 60, source: Fixture.thirdParty)
        let c = Fixture.workout(3, start: 480, minutes: 60, source: sourced(Fixture.watch, external: nil, bundle: "com.other.app", name: "Other"))
        let result = WorkoutDeduplicator.deduplicate([a, b, c])
        XCTAssertEqual(result.entries.count, 3)
        // 排序最前的 a 被计入；b 与 a 疑似而被排除；c 只与 b 疑似，b 已被排除，c 不被连带排除。
        let counted = Set(result.entries.filter(\.countsTowardTotals).map { $0.primary.id })
        XCTAssertTrue(counted.contains(Fixture.uuid(1)))
        XCTAssertTrue(counted.contains(Fixture.uuid(3)))
        XCTAssertFalse(counted.contains(Fixture.uuid(2)))
    }

    func testResultIsIndependentOfInputOrder() {
        let records = [
            Fixture.workout(1),
            Fixture.workout(2, start: 40, source: Fixture.thirdParty),
            Fixture.workout(3, activity: .walking, start: 7_200, distanceKm: 3),
            Fixture.workout(4, activity: .walking, start: 7_230, distanceKm: 3, source: Fixture.thirdParty),
        ]
        let expected = WorkoutDeduplicator.deduplicate(records).entries.map { "\($0.primary.id)-\($0.countsTowardTotals)" }
        for seed in 0..<20 {
            var generator = SeededGenerator(seed: UInt64(seed))
            let shuffled = records.shuffled(using: &generator)
            let actual = WorkoutDeduplicator.deduplicate(shuffled).entries.map { "\($0.primary.id)-\($0.countsTowardTotals)" }
            XCTAssertEqual(actual, expected)
        }
    }

    func testIndependentWorkoutsAreUntouched() {
        let rides = (0..<5).map { Fixture.workout($0 + 1, start: Double($0) * 86_400) }
        let result = WorkoutDeduplicator.deduplicate(rides)
        XCTAssertEqual(result.entries.count, 5)
        XCTAssertTrue(result.entries.allSatisfy { $0.duplicateStatus == .unique && $0.countsTowardTotals })
        XCTAssertEqual(result.suspectedExcludedFromTotals, 0)
    }

    func testDuplicateDetectionIsTimeZoneIndependent() {
        // 判定只用绝对时刻；同一对记录在任意时区下结论一致（无本地时间参与）。
        let a = Fixture.workout(1)
        let b = Fixture.workout(2, start: 40, source: Fixture.thirdParty)
        let before = WorkoutDuplicateDetector.relation(a, b)
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        for name in ["Asia/Tokyo", "America/Los_Angeles", "Pacific/Kiritimati"] {
            NSTimeZone.default = TimeZone(identifier: name)!
            XCTAssertEqual(WorkoutDuplicateDetector.relation(a, b), before)
        }
    }

    // MARK: 辅助

    private func sourced(_ base: WorkoutSourceInfo, external: String?, bundle: String? = nil, name: String? = nil) -> WorkoutSourceInfo {
        WorkoutSourceInfo(
            name: name ?? base.name,
            bundleIdentifier: bundle ?? base.bundleIdentifier,
            deviceName: base.deviceName, deviceModel: base.deviceModel, deviceHardwareVersion: base.deviceHardwareVersion,
            externalIdentifier: external, syncIdentifier: base.syncIdentifier
        )
    }

    private func otherDeviceSource() -> WorkoutSourceInfo {
        WorkoutSourceInfo(
            name: "第三方", bundleIdentifier: "com.example.fit",
            deviceName: "Apple Watch", deviceModel: "Watch", deviceHardwareVersion: "Watch6,1"
        )
    }
}

/// 可复现的随机数，用于“与输入顺序无关”的测试。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
