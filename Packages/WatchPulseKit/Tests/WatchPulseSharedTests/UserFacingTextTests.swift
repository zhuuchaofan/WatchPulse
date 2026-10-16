import XCTest
@testable import WatchPulseShared

/// 用户可见文案的回归测试（UX Writing Audit）：
/// 不向用户展示系统原始错误、内部术语与统计口径；运动科学用语不过度确定；缺失数据不包装成正常结论。
final class UserFacingTextTests: XCTestCase {
    /// 模拟一条系统原始错误信息。
    private let rawSystemError = "Error Domain=com.apple.healthkit Code=5 \"Authorization not determined\""

    /// 普通用户界面中不应出现的技术词。
    private let technicalTerms = ["HealthKit", "SDNN", "Error Domain", "Code=", "口径", "对端", "会话", "样本", "可展示", "进步比较"]

    private func assertPlain(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        for term in technicalTerms {
            XCTAssertFalse(text.contains(term), "“\(text)” 不应包含 “\(term)”", file: file, line: line)
        }
    }

    // MARK: - 错误信息

    func testHealthDataErrorsNeverShowRawSystemErrors() {
        let errors: [HealthDataError] = [
            .healthDataUnavailable,
            .protectedDataUnavailable,
            .authorizationFailed(reason: rawSystemError),
            .queryFailed(reason: rawSystemError),
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty, "\(error)")
            XCTAssertFalse(text.contains(rawSystemError), "\(error)")
            assertPlain(text)
        }
        // 可重试的错误要给出下一步。
        XCTAssertTrue(HealthDataError.queryFailed(reason: rawSystemError).errorDescription!.contains("重试"))
        XCTAssertTrue(HealthDataError.authorizationFailed(reason: rawSystemError).errorDescription!.contains("设置"))
        XCTAssertTrue(HealthDataError.protectedDataUnavailable.errorDescription!.contains("解锁"))
    }

    func testHealthDataErrorKeepsDiagnosticsForDevelopers() {
        XCTAssertTrue(HealthDataError.queryFailed(reason: rawSystemError).diagnosticDescription.contains(rawSystemError))
        XCTAssertTrue(HealthDataError.authorizationFailed(reason: "x").diagnosticDescription.contains("authorizationFailed"))
    }

    func testWorkoutSessionErrorsNeverShowRawSystemErrors() {
        let errors: [WorkoutSessionError] = [
            .healthDataUnavailable,
            .authorizationFailed(reason: rawSystemError),
            .sessionStartFailed(reason: rawSystemError),
            .sessionFailed(reason: rawSystemError),
            .noActiveSession,
            .invalidTransition(from: .paused, action: "暂停"),
            .notConnected,
            .mirroringUnavailable,
            .saveFailed(reason: rawSystemError),
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty, "\(error)")
            XCTAssertFalse(text.contains(rawSystemError), "\(error)")
            assertPlain(text)
        }
        let save = WorkoutSessionError.saveFailed(reason: rawSystemError)
        XCTAssertTrue(save.errorDescription!.contains("「健康」App"), "保存失败要告诉用户去哪里确认")
        XCTAssertTrue(save.diagnosticDescription.contains(rawSystemError), "原始原因保留给调试")
    }

    // MARK: - 运动科学用语

    func testPersonalZoneNamesAvoidMisleadingTrainingClaims() {
        for zone in TrainingZone.allCases {
            for word in ["燃脂", "乳酸阈", "无氧", "极限"] {
                XCTAssertFalse(zone.name.contains(word), "\(zone.title) \(zone.name)")
            }
        }
        XCTAssertEqual(TrainingZone.z3.name, "有氧", "骑行码表等处仍以 Z3 有氧显示")
    }

    // MARK: - 数据可信度：默认通俗结论，技术依据收进详情

    func testHeartRateSummaryIsPlainAndHonestForEveryLevel() {
        let workout = Fixture.workout(1)
        let complete = HeartRateEvidence.evaluate(
            WorkoutHeartRateSeries(points: Fixture.heartRate(for: workout), attribution: .workoutAssociated), for: workout
        )
        let partial = HeartRateEvidence.evaluate(
            WorkoutHeartRateSeries(points: Fixture.heartRate(for: workout, to: 1_800), attribution: .sameDevice), for: workout
        )
        let notLoaded = HeartRateEvidence.unavailable(reason: .notLoaded)
        let none = HeartRateEvidence.unavailable(reason: .noSamples)

        XCTAssertEqual(complete.usability, .comparable)
        XCTAssertEqual(partial.usability, .displayOnly)

        for evidence in [complete, partial, notLoaded, none] {
            assertPlain(WorkoutAnalysisPresentation.heartRateSummary(evidence))
        }
        XCTAssertTrue(WorkoutAnalysisPresentation.heartRateSummary(complete).contains("可以和过去的运动比较"))
        XCTAssertTrue(WorkoutAnalysisPresentation.heartRateSummary(partial).contains("仅供参考"))
        // 没有数据 / 读取失败不能说成“完整”或“可以比较”。
        for evidence in [notLoaded, none] {
            let text = WorkoutAnalysisPresentation.heartRateSummary(evidence)
            XCTAssertFalse(text.contains("完整"), text)
            XCTAssertFalse(text.contains("可以"), text)
        }
        XCTAssertTrue(WorkoutAnalysisPresentation.heartRateSummary(notLoaded).contains("没有读取成功"), "读取失败不等于没有心率")
    }

    func testHeartRateIssueAndLevelWordingIsPlain() {
        let issues: [HeartRateIssue] = [
            .noSamples, .attributionAllSources, .attributionSameDeviceTimeRange, .lowCoverage,
            .partialCoverage, .tooFewSamples, .manyAnomalies, .notLoaded,
        ]
        for issue in issues { assertPlain(issue.message) }
        for level in [HeartRateUsability.unavailable, .displayOnly, .summary, .comparable] { assertPlain(level.title) }
    }

    // MARK: - 运动后反馈

    func testFeedbackReasonsAreReadable() {
        let reasons: [WorkoutComparabilityReason] = [
            .differentActivity, .differentLocation, .notEligible, .differentSource,
            .differentDevice, .deviceUnknown, .durationMismatch, .distanceMismatch,
        ]
        for reason in reasons { assertPlain(reason.message) }
        let blockers: [WorkoutAnalysisBlocker] = [.invalidTimeRange, .excludedAsSuspectedDuplicate, .suspectedDuplicate, .locationUnknown]
        for blocker in blockers { assertPlain(blocker.message) }
        let unavailable: [WorkoutFeedbackUnavailableReason] = [
            .noData, .workoutNotEligible, .heartRateNotComparable(.displayOnly), .noPersonalZones,
        ]
        for reason in unavailable { assertPlain(reason.message) }
        assertPlain(WorkoutFeedbackPresentation.disclaimer)
    }

    // MARK: - 概念首次出现时的解释

    func testUncommonConceptsHaveOneSentenceExplanations() {
        let hrv = try? XCTUnwrap(HealthMetricKind.heartRateVariability.explanation)
        XCTAssertTrue(hrv?.contains("HRV") == true)
        XCTAssertTrue(hrv?.contains("和自己") == true, "HRV 个体差异大，要提示只和自己比较")
        XCTAssertNotNil(HealthMetricKind.restingHeartRate.explanation)
        XCTAssertNil(HealthMetricKind.stepCount.explanation, "常见指标不加解释，避免说明过长")
        XCTAssertTrue(BaselineComparison.baselineExplanation.contains("平时"))
        for kind in HealthMetricKind.allCases {
            if let text = kind.explanation { assertPlain(text) }
        }
    }
}
