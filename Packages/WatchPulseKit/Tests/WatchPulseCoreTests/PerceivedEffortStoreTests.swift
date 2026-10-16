import Foundation
import XCTest
@testable import WatchPulseCore
import WatchPulseShared

final class PerceivedEffortStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_772_359_200)

    private func workout(_ n: Int) -> WorkoutRecord {
        WorkoutRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
            activity: .running, location: .outdoor, startDate: now.addingTimeInterval(Double(n) * 86_400),
            endDate: now.addingTimeInterval(Double(n) * 86_400 + 1_800), duration: 1_800, sourceName: "X"
        )
    }

    func testOneRecordPerWorkoutUpsertEditAndDelete() async throws {
        let store = InMemoryPerceivedEffortStore()
        let w = workout(1)
        let firstSaved = try await store.save(for: w, effort: 5, feelings: [.normal], now: now)
        let first = try XCTUnwrap(firstSaved)
        let editedSaved = try await store.save(for: w, effort: 8, feelings: [.tired, .sore], now: now.addingTimeInterval(60))
        let edited = try XCTUnwrap(editedSaved)
        XCTAssertEqual(first.id, edited.id, "同一运动只有一条记录")
        XCTAssertEqual(edited.createdAt, now)
        let all = await store.allRecords()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].effort, 8)
        try await store.delete(workoutID: w.id)
        let remaining = await store.allRecords()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSavingEmptyEntryRemovesExistingRecord() async throws {
        let store = InMemoryPerceivedEffortStore()
        let w = workout(1)
        _ = try await store.save(for: w, effort: 5, feelings: [], now: now)
        let result = try await store.save(for: w, effort: nil, feelings: [], now: now)
        XCTAssertNil(result)
        let all = await store.allRecords()
        XCTAssertTrue(all.isEmpty)
    }

    func testRecordLookupIgnoresOrphans() async throws {
        let store = InMemoryPerceivedEffortStore()
        let gone = workout(1), kept = workout(2)
        _ = try await store.save(for: gone, effort: 5, feelings: [.normal], now: now)
        _ = try await store.save(for: kept, effort: 6, feelings: [.normal], now: now)
        let coverage = DateInterval(start: now, end: now.addingTimeInterval(30 * 86_400))
        let summary = await store.reconcile(with: [kept], coverage: coverage, now: now)
        XCTAssertEqual(summary.newlyOrphaned, 1)
        let linkedGone = await store.linkedRecord(forWorkoutID: gone.id)
        let linkedKept = await store.linkedRecord(forWorkoutID: kept.id)
        XCTAssertNil(linkedGone, "孤儿记录不参与展示与分析")
        XCTAssertNotNil(linkedKept)
        let orphans = await store.orphanedRecords()
        XCTAssertEqual(orphans.count, 1)
    }

    func testPurgeOnlyRemovesOrphansAndOnlyWhenAsked() async throws {
        let store = InMemoryPerceivedEffortStore()
        let gone = workout(1), kept = workout(2)
        _ = try await store.save(for: gone, effort: 5, feelings: [.normal], now: now)
        _ = try await store.save(for: kept, effort: 6, feelings: [.normal], now: now)
        _ = await store.reconcile(with: [kept], coverage: DateInterval(start: now, end: now.addingTimeInterval(30 * 86_400)), now: now)
        let beforePurge = await store.allRecords()
        XCTAssertEqual(beforePurge.count, 2, "对账不会删除任何记录")
        let removed = await store.purgeOrphans()
        XCTAssertEqual(removed, 1)
        let after = await store.allRecords()
        XCTAssertEqual(after.map(\.key.workoutID), [kept.id])
    }
}
