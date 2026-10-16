import Foundation

/// 训练中心与进步页使用的简短版运动后反馈：一句话说明比较了什么（或为什么没有比较），
/// 再列出已完成比较的指标。完整版见 `WorkoutFeedbackPresentation.headline` 与运动详情。
extension WorkoutFeedbackPresentation {
    public static func briefHeadline(_ feedback: WorkoutFeedback) -> String {
        let kind = "\(feedback.location.title)\(feedback.activity.title)"
        switch feedback.status {
        case .compared:
            return "与之前 \(feedback.comparableCount) 次可比的\(kind)相比"
        case .insufficientSamples(let found, let required):
            return "可比的\(kind)目前有 \(found) 次，至少需要 \(required) 次才能比较。再多记录几次相似的运动，就会出现对比。"
        case .notEligible(let blockers):
            let reasons = blockers.map(\.message).joined(separator: "；")
            return "这次运动暂不和过去比较\(reasons.isEmpty ? "" : "：\(reasons)")。"
        }
    }

    /// 已完成比较的指标，例如“运动时长比最近 4 次平均（40:00）长 8%”。没有完成比较的指标不列出。
    public static func comparedLines(_ feedback: WorkoutFeedback) -> [String] {
        feedback.metrics.compactMap { item -> String? in
            guard case .compared = item.outcome else { return nil }
            return title(of: item.metric, activity: feedback.activity) + comparison(item, activity: feedback.activity)
        }
    }
}
