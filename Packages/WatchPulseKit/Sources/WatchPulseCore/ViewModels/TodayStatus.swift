import Foundation
import WatchPulseShared

/// 「今日」首页顶部的状态小结：结论 + 原因 + 行动。
///
/// 只把静息心率 / 心率变异性与**你自己**的平时水平比较，不合成分数，不判断恢复程度或健康状况；
/// 数据不足时如实说明“还在了解”，不包装成正常结论。
public struct TodayStatus: Hashable, Sendable {
    public enum Level: Hashable, Sendable {
        /// 与平时接近。
        case steady
        /// 与平时有差异（只描述差异，不下结论）。
        case changed
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

    public init(level: Level, headline: String, reason: String, action: Action) {
        self.level = level
        self.headline = headline
        self.reason = reason
        self.action = action
    }

    static let comparedKinds: [HealthMetricKind] = [.restingHeartRate, .heartRateVariability]

    public static func make(from snapshot: HealthDashboardSnapshot) -> TodayStatus {
        let baselines = comparedKinds.compactMap { snapshot.card(for: $0)?.baseline }
        let ready = baselines.filter { $0.sufficiency == .sufficient }

        if !ready.isEmpty {
            let changed = ready.filter { ($0.direction ?? .flat) != .flat }
            guard let first = changed.first else {
                let names = ready.map(\.kind.title).joined(separator: "和")
                return TodayStatus(
                    level: .steady,
                    headline: "和平时差不多",
                    reason: "最近 7 天的\(names)和你自己的平时水平接近。",
                    action: .openTraining
                )
            }
            let parts = changed.map { comparison -> String in
                let word = comparison.direction == .up ? "高" : "低"
                return "\(comparison.kind.title)比平时\(word) \(comparison.kind.formattedValueWithUnit(abs(comparison.delta ?? 0)))"
            }
            return TodayStatus(
                level: .changed,
                headline: "和平时有些不同",
                reason: "最近 7 天，\(parts.joined(separator: "，"))。这只是和你自己的过去比较，不代表健康状况。",
                action: .openTrend(first.kind)
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
