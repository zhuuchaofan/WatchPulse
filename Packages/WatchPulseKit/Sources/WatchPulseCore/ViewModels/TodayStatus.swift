import Foundation
import WatchPulseShared

/// 「今日」首页顶部的状态小结：结论 + 原因 + 行动。
///
/// 只把静息心率 / 心率变异性与**你自己**的平时水平比较，不合成分数，不判断恢复程度或健康状况；
/// 数据不足时如实说明“还在了解”，不包装成正常结论。
///
/// 差值的显示阈值（1 次/分、1 毫秒）只是取整，没有经过校准，因此首页**不再**用“和平时有些不同 / 差不多”下结论：
/// 只说明对比的时间范围，并列出最近 7 天与平时的数值，由用户自己看。
public struct TodayStatus: Hashable, Sendable {
    public enum Level: Hashable, Sendable {
        /// 平时水平已够用：列出最近 7 天与平时的数值（不判断差异大小）。
        case compared
        /// 平时水平还在积累。
        case learning
        /// 没有静息心率 / 心率变异性可比较。
        case limited
    }

    public enum Action: Hashable, Sendable {
        case openTrend(HealthMetricKind)
        case openTraining

        public var title: String {
            switch self {
            case .openTrend(let kind): return "查看\(kind.title)变化"
            case .openTraining: return "看看本周训练"
            }
        }
    }

    public let level: Level
    /// 结论。
    public let headline: String
    /// 原因（一两句话，附带“只和自己比较”的说明）。
    public let reason: String
    /// 建议的下一步。
    public let action: Action
    /// 对比用的“最近 7 天”（不含今天）。只有 `.compared` 才有。
    public let observation: DateInterval?

    public init(level: Level, headline: String, reason: String, action: Action, observation: DateInterval? = nil) {
        self.level = level
        self.headline = headline
        self.reason = reason
        self.action = action
        self.observation = observation
    }

    static let comparedKinds: [HealthMetricKind] = [.restingHeartRate, .heartRateVariability]

    public static func make(from snapshot: HealthDashboardSnapshot) -> TodayStatus {
        let baselines = comparedKinds.compactMap { snapshot.card(for: $0)?.baseline }
        let ready = baselines.filter { $0.sufficiency == .sufficient }

        if let first = ready.first {
            let names = ready.map(\.kind.title).joined(separator: "和")
            return TodayStatus(
                level: .compared,
                headline: ready.count > 1 ? "\(names)都有记录，可以和你的平时对比" : "\(names)有记录，可以和你的平时对比",
                reason: "只和你自己之前 4 周的典型值比较，这里只列数值，不判断好坏。",
                action: .openTrend(first.kind),
                observation: first.windows.observation
            )
        }

        if !baselines.isEmpty {
            return TodayStatus(
                level: .learning,
                headline: "正在了解你的平时水平",
                reason: "再连续佩戴 Apple Watch 几天，就能看到最近 7 天和平时的对比。",
                action: .openTraining
            )
        }

        return TodayStatus(
            level: .limited,
            headline: "今天的数据还不多",
            reason: "戴着 Apple Watch 休息、睡觉之后，这里会给出今天的小结。",
            action: .openTraining
        )
    }
}
