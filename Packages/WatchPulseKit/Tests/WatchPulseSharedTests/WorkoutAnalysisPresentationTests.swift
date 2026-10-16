import XCTest
@testable import WatchPulseShared

final class WorkoutAnalysisPresentationTests: XCTestCase {
    func testDuplicateLabels() {
        let a = Fixture.workout(1)
        let suspect = Fixture.workout(2, start: 40, source: Fixture.thirdParty)
        let independent = Fixture.workout(3, start: 5 * 86_400)
        let confirmedA = Fixture.workout(4, start: 10 * 86_400, source: WorkoutSourceInfo(name: "A", bundleIdentifier: "a", externalIdentifier: "E"))
        let confirmedB = Fixture.workout(5, start: 10 * 86_400, source: WorkoutSourceInfo(name: "B", bundleIdentifier: "b", externalIdentifier: "E"))
        let result = WorkoutDeduplicator.deduplicate([a, suspect, independent, confirmedA, confirmedB])

        XCTAssertEqual(WorkoutAnalysisPresentation.duplicateLabel(for: a.id, in: result), "疑似重复")
        XCTAssertEqual(WorkoutAnalysisPresentation.duplicateLabel(for: suspect.id, in: result), "疑似重复")
        XCTAssertNil(WorkoutAnalysisPresentation.duplicateLabel(for: independent.id, in: result))
        let primary = result.entries.first { $0.mergedDuplicates.count == 1 }!
        let merged = primary.mergedDuplicates[0]
        XCTAssertEqual(WorkoutAnalysisPresentation.duplicateLabel(for: primary.id, in: result), "含 1 个重复来源")
        XCTAssertEqual(WorkoutAnalysisPresentation.duplicateLabel(for: merged.id, in: result), "重复记录")
    }

    func testHeartRateLinesNameTheLevelAndTheReasons() {
        let workout = Fixture.workout(1)
        let series = WorkoutHeartRateSeries(points: Fixture.heartRate(for: workout, to: 1_800), attribution: .sameDevice)
        let evidence = HeartRateEvidence.evaluate(series, for: workout)
        let lines = WorkoutAnalysisPresentation.heartRateLines(evidence)
        XCTAssertTrue(lines.contains { $0.contains("仅供参考") })
        XCTAssertTrue(lines.contains { $0.contains("占 50%") })
        XCTAssertTrue(lines.contains { $0.contains("同一设备") })
        XCTAssertFalse(lines.joined().contains("疾病"))
    }

    func testComparableLevelWording() {
        let workout = Fixture.workout(1)
        let evidence = HeartRateEvidence.evaluate(
            WorkoutHeartRateSeries(points: Fixture.heartRate(for: workout), attribution: .workoutAssociated), for: workout
        )
        XCTAssertTrue(WorkoutAnalysisPresentation.heartRateLines(evidence).first!.contains("可与过去的运动比较"))
    }

    func testUnavailableWording() {
        let lines = WorkoutAnalysisPresentation.heartRateLines(HeartRateEvidence.unavailable(reason: .notLoaded))
        XCTAssertTrue(lines.first!.contains("没有心率数据"))
    }

    func testSourceLinesShowDeviceAndNeverInventValues() {
        let lines = WorkoutAnalysisPresentation.sourceLines(Fixture.watch)
        XCTAssertTrue(lines.contains { $0.contains("体能训练") })
        XCTAssertTrue(lines.contains { $0.contains("Watch6,1") })
        let bare = WorkoutAnalysisPresentation.sourceLines(WorkoutSourceInfo(name: "X"))
        XCTAssertTrue(bare.contains { $0.contains("设备：未记录") })
    }
}
