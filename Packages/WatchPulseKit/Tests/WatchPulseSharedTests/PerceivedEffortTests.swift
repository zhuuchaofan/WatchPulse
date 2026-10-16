import XCTest
@testable import WatchPulseShared

final class PerceivedEffortTests: XCTestCase {
    private let now = Fixture.base.addingTimeInterval(10 * 86_400)

    private func record(for workout: WorkoutRecord, effort: Int? = 6, feelings: Set<BodyFeeling> = [.tired], at date: Date? = nil) -> PerceivedEffortRecord {
        PerceivedEffortRecord(id: Fixture.uuid(900 + Int(workout.id.uuidString.suffix(3))!), workout: workout, effort: effort, feelings: feelings, now: date ?? now)!
    }

    // MARK: 模型

    func testEmptyEntryIsRejected() {
        let w = Fixture.workout(1)
        XCTAssertNil(PerceivedEffortRecord(id: UUID(), workout: w, effort: nil, feelings: [], now: now))
    }

    func testOutOfRangeEffortIsRejected() {
        let w = Fixture.workout(1)
        XCTAssertNil(PerceivedEffortRecord(id: UUID(), workout: w, effort: 0, feelings: [], now: now))
        XCTAssertNil(PerceivedEffortRecord(id: UUID(), workout: w, effort: 11, feelings: [.normal], now: now))
        XCTAssertNotNil(PerceivedEffortRecord(id: UUID(), workout: w, effort: 10, feelings: [], now: now))
        XCTAssertNotNil(PerceivedEffortRecord(id: UUID(), workout: w, effort: nil, feelings: [.normal], now: now))
    }

    func testEditKeepsCreatedAtAndValidates() throws {
        let w = Fixture.workout(1)
        let original = record(for: w)
        let later = now.addingTimeInterval(3_600)
        let edited = try XCTUnwrap(original.updating(effort: 8, feelings: [.sore], now: later))
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.createdAt, original.createdAt)
        XCTAssertEqual(edited.updatedAt, later)
        XCTAssertEqual(edited.effort, 8)
        XCTAssertNil(original.updating(effort: nil, feelings: [], now: later), "清空全部内容应改为删除，而不是保存空记录")
    }

    func testCodableRoundTripAndSchemaVersion() throws {
        let original = record(for: Fixture.workout(1))
        let decoded = try JSONDecoder().decode(PerceivedEffortRecord.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.schemaVersion, PerceivedEffortRecord.currentSchemaVersion)
    }

    // MARK: 运动记录消失 / 变化

    func testLinkedWhenWorkoutStillPresent() {
        let w = Fixture.workout(1)
        let result = PerceivedEffortReconciler.reconcile([record(for: w)], workouts: [w], coverage: coverage(), now: now)
        XCTAssertEqual(result.records[0].linkState, .linked)
        XCTAssertEqual(result.summary, .init())
    }

    func testMissingWorkoutBecomesOrphanedButIsNeverDeleted() {
        let w = Fixture.workout(1), other = Fixture.workout(2, start: 86_400)
        let result = PerceivedEffortReconciler.reconcile([record(for: w)], workouts: [other], coverage: coverage(), now: now)
        XCTAssertEqual(result.records.count, 1, "不得自动删除用户填写的内容")
        XCTAssertEqual(result.records[0].linkState, .orphaned(since: now))
        XCTAssertEqual(result.summary.newlyOrphaned, 1)
        XCTAssertEqual(result.records[0].effort, 6)
    }

    func testOrphanSinceDateIsKeptAcrossReconciliations() {
        let w = Fixture.workout(1), other = Fixture.workout(2, start: 86_400)
        let first = PerceivedEffortReconciler.reconcile([record(for: w)], workouts: [other], coverage: coverage(), now: now)
        let second = PerceivedEffortReconciler.reconcile(first.records, workouts: [other], coverage: coverage(), now: now.addingTimeInterval(86_400))
        XCTAssertEqual(second.records[0].linkState, .orphaned(since: now))
        XCTAssertEqual(second.summary.newlyOrphaned, 0)
    }

    func testUUIDChangeIsRelinkedByUniqueFingerprint() {
        let old = Fixture.workout(1)
        let restored = Fixture.workout(7) // 备份还原后 UUID 变化，其余一致
        let result = PerceivedEffortReconciler.reconcile([record(for: old)], workouts: [restored], coverage: coverage(), now: now)
        XCTAssertEqual(result.records[0].key.workoutID, restored.id)
        XCTAssertEqual(result.records[0].linkState, .linked)
        XCTAssertEqual(result.summary.relinked, 1)
    }

    func testAmbiguousFingerprintIsNotRelinked() {
        let old = Fixture.workout(1)
        let twinA = Fixture.workout(7), twinB = Fixture.workout(8)
        let result = PerceivedEffortReconciler.reconcile([record(for: old)], workouts: [twinA, twinB], coverage: coverage(), now: now)
        XCTAssertEqual(result.records[0].key.workoutID, old.id)
        XCTAssertEqual(result.records[0].linkState, .orphaned(since: now))
    }

    func testFingerprintDoesNotMatchDifferentSourceOrActivityOrTime() {
        let old = Fixture.workout(1)
        let candidates = [
            Fixture.workout(2, source: Fixture.thirdParty),
            Fixture.workout(3, activity: .running),
            Fixture.workout(4, start: 3_600),
            Fixture.workout(5, minutes: 61),
        ]
        let result = PerceivedEffortReconciler.reconcile([record(for: old)], workouts: candidates, coverage: coverage(), now: now)
        XCTAssertEqual(result.records[0].linkState, .orphaned(since: now))
    }

    func testFingerprintRequiresMatchingExternalIdentifierWhenBothHaveOne() {
        let old = Fixture.workout(1, source: externallyIdentified("EXT-A"))
        let otherWorkout = Fixture.workout(7, source: externallyIdentified("EXT-B"))
        let sameWorkout = Fixture.workout(8, source: externallyIdentified("EXT-A"))
        XCTAssertFalse(WorkoutKey(workout: old).fingerprintMatches(otherWorkout), "外部标识不同说明是另一次运动")
        XCTAssertTrue(WorkoutKey(workout: old).fingerprintMatches(sameWorkout))
        XCTAssertTrue(WorkoutKey(workout: old).fingerprintMatches(Fixture.workout(9)), "一方没有外部标识时只按其余指纹判断")
    }

    func testKeyWithoutExternalIdentifierDecodesFromEarlierEncoding() throws {
        // 早期编码没有 externalKeys 字段，仍应可以解码。
        let key = WorkoutKey(workout: Fixture.workout(1))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(key)) as? [String: Any])
        object.removeValue(forKey: "externalKeys")
        let decoded = try JSONDecoder().decode(WorkoutKey.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.externalKeys)
        XCTAssertTrue(decoded.fingerprintMatches(Fixture.workout(2)))
    }

    private func externallyIdentified(_ identifier: String) -> WorkoutSourceInfo {
        WorkoutSourceInfo(
            name: Fixture.watch.name, bundleIdentifier: Fixture.watch.bundleIdentifier,
            deviceName: Fixture.watch.deviceName, deviceModel: Fixture.watch.deviceModel,
            deviceHardwareVersion: Fixture.watch.deviceHardwareVersion, externalIdentifier: identifier
        )
    }

    func testOneWorkoutIsNeverClaimedByTwoRecords() {
        let a = Fixture.workout(1)
        let b = Fixture.workout(2) // 同指纹
        let restored = Fixture.workout(9)
        let result = PerceivedEffortReconciler.reconcile([record(for: a), record(for: b)], workouts: [restored], coverage: coverage(), now: now)
        XCTAssertLessThanOrEqual(result.records.filter { $0.key.workoutID == restored.id }.count, 1)
    }

    func testReappearingWorkoutRestoresOrphan() {
        let w = Fixture.workout(1)
        var orphan = record(for: w)
        orphan.linkState = .orphaned(since: now.addingTimeInterval(-86_400))
        let result = PerceivedEffortReconciler.reconcile([orphan], workouts: [w], coverage: coverage(), now: now)
        XCTAssertEqual(result.records[0].linkState, .linked)
        XCTAssertEqual(result.summary.restored, 1)
    }

    func testWorkoutsOutsideFetchedCoverageAreNotJudgedMissing() {
        let old = Fixture.workout(1, start: -400 * 86_400)
        let recent = Fixture.workout(2, start: 0)
        let narrow = DateInterval(start: Fixture.base.addingTimeInterval(-30 * 86_400), end: Fixture.base.addingTimeInterval(86_400))
        let result = PerceivedEffortReconciler.reconcile([record(for: old)], workouts: [recent], coverage: narrow, now: now)
        XCTAssertEqual(result.records[0].linkState, .linked, "只读取了最近一段运动，更早的记录不能因此判为消失")
    }

    func testEmptyWorkoutListChangesNothing() {
        // HealthKit 无法区分“没有数据”与“未授权读取”，空列表不能让所有记录变孤儿。
        let w = Fixture.workout(1)
        let result = PerceivedEffortReconciler.reconcile([record(for: w)], workouts: [], coverage: coverage(), now: now)
        XCTAssertEqual(result.records[0].linkState, .linked)
        XCTAssertEqual(result.summary, .init())
    }

    private func coverage() -> DateInterval {
        DateInterval(start: Fixture.base.addingTimeInterval(-365 * 86_400), end: Fixture.base.addingTimeInterval(365 * 86_400))
    }
}
