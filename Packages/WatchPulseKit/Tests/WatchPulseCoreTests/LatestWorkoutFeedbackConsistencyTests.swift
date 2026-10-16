import Foundation
import XCTest
@testable import WatchPulseCore
import WatchPulseShared

/// 「运动」页最近一次运动、「进步」页“和过去的自己比”、运动详情三处对同一次运动的比较必须一致。
///
/// 三处界面都用 `WorkoutFeedbackViewModel(workout:service:)`（默认参数）读取。这里用“混合多种运动、
/// 同类历史在最近 12 条之外”的记录复现旧问题：进步页原来用只为最近 12 条运动读取心率的数据直接计算，
/// 较早的同类运动没有心率，平均心率一项就和另外两处不同。
@MainActor
final class LatestWorkoutFeedbackConsistencyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_780_574_400)
    private let day: TimeInterval = 86_400

    private func workout(_ n: Int, daysAfterBase: Double, activity: WorkoutActivityKind, distanceKm: Double) -> WorkoutRecord {
        let start = base.addingTimeInterval(daysAfterBase * day)
        return WorkoutRecord(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
            activity: activity, location: .outdoor,
            startDate: start, endDate: start.addingTimeInterval(3_600), duration: 3_600,
            distanceMeters: distanceKm * 1000, averageHeartRate: 140, sourceName: "体能训练"
        )
    }

    private func heartRates(_ workouts: [WorkoutRecord]) -> [UUID: MockHealthDataService.Behavior<[HeartRatePoint]>] {
        Dictionary(uniqueKeysWithValues: workouts.map { workout in
            (workout.id, .value(stride(from: 0.0, through: 3_600, by: 5).map {
                HeartRatePoint(date: workout.startDate.addingTimeInterval($0), beatsPerMinute: 140)
            }))
        })
    }

    /// 最近一次骑行（第 30 天）+ 之间 12 次跑步（第 18～29 天）+ 更早 5 次骑行（第 1～5 天）。
    private func mixedHistory() -> (latest: WorkoutRecord, service: MockWorkoutHistoryService) {
        let latest = workout(100, daysAfterBase: 30, activity: .cycling, distanceKm: 20)
        let runs = (0..<12).map { workout(200 + $0, daysAfterBase: 18 + Double($0), activity: .running, distanceKm: 8) }
        let olderRides = (1...5).map { workout($0, daysAfterBase: Double($0), activity: .cycling, distanceKm: 20) }
        let all = [latest] + runs + olderRides
        return (latest, MockWorkoutHistoryService(workouts: .value(all), heartRates: heartRates(all)))
    }

    private func load(_ workout: WorkoutRecord, _ service: MockWorkoutHistoryService) async -> WorkoutFeedbackResult? {
        let viewModel = WorkoutFeedbackViewModel(workout: workout, service: service)
        await viewModel.load()
        return viewModel.state.value
    }

    func testOldProgressPathDisagreesOnHeartRate() async throws {
        let (latest, service) = mixedHistory()
        // 修复前进步页的做法：读取 200 条，只为最近 12 条（不分类型）读取心率，再直接计算。
        let set = try await WorkoutAnalysisLoader(service: service, maximumHeartRateFetches: 12).load(limit: 200)
        guard let target = set.record(containing: latest.id) else { return XCTFail("应读到最近一次骑行") }
        let oldFeedback = WorkoutFeedbackCalculator.feedback(for: target, among: set.records)

        guard let shared = await load(latest, service) else { return XCTFail("应加载成功") }
        XCTAssertNotEqual(
            oldFeedback.metric(.averageHeartRate)?.outcome,
            shared.feedback.metric(.averageHeartRate)?.outcome,
            "复现：旧做法下较早的骑行没有心率，平均心率一项和运动页 / 详情不同"
        )
    }

    func testAllThreePagesGiveTheSameFeedback() async {
        let (latest, service) = mixedHistory()
        // 运动页、进步页、运动详情各自创建一次，和界面中的用法相同。
        let workoutTab = await load(latest, service)
        let progressTab = await load(latest, service)
        let detail = await load(latest, service)

        guard let workoutTab, let progressTab, let detail else { return XCTFail("三处都应加载成功") }
        XCTAssertEqual(workoutTab, progressTab)
        XCTAssertEqual(workoutTab, detail)
        XCTAssertEqual(workoutTab.feedback.status, .compared)
        XCTAssertEqual(workoutTab.feedback.comparableCount, 5, "较早的 5 次骑行都参与比较")
        guard case .compared(_, _, _, _, let baseline)? = workoutTab.feedback.metric(.averageHeartRate)?.outcome else {
            return XCTFail("同类历史在最近 12 条之外时，平均心率仍应可比较")
        }
        XCTAssertEqual(baseline.sampleCount, 5)
        // 界面上显示的文字也相同。
        XCTAssertEqual(
            WorkoutFeedbackPresentation.comparedLines(progressTab.feedback),
            WorkoutFeedbackPresentation.comparedLines(detail.feedback)
        )
    }

    func testProgressTrendLoaderNoLongerReadsHeartRate() async throws {
        let (_, service) = mixedHistory()
        _ = try await WorkoutAnalysisLoader(service: service, maximumHeartRateFetches: 0).load(limit: 200)
        XCTAssertEqual(service.heartRateFetchCount, 0, "4 周趋势只用次数 / 时长 / 距离")
    }
}
