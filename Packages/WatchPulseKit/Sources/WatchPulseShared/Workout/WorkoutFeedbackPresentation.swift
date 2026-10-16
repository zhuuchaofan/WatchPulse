import Foundation

/// 运动后反馈的界面文案。只描述数值差异与证据（对比对象、样本数），不评价进步 / 退步，不做健康判断。
public enum WorkoutFeedbackPresentation {
    public static let disclaimer = "这里只列出本次和过去同类运动的数值差别，不评价进步或退步。路线、天气、身体状态和设备都会影响数据。"

    /// 顶部说明：比较了什么，或为什么不比较。
    public static func headline(_ feedback: WorkoutFeedback) -> String {
        let kind = "\(feedback.location.title)\(feedback.activity.title)"
        let days = Int((feedback.configuration.lookback / 86_400).rounded())
        switch feedback.status {
        case .compared:
            return "与你之前 \(days) 天内可比的\(kind)比较：记录来源相同、距离或时长相近，每项取最近几次（最多 \(feedback.configuration.maximumSamples) 次）。"
        case .insufficientSamples(let found, let required):
            return "之前 \(days) 天内可比的\(kind)有 \(found) 次，至少需要 \(required) 次才能比较。下面先只显示本次数据；之后多记录几次相似的运动，就会出现对比。"
        case .notEligible(let blockers):
            let reasons = blockers.map(\.message).joined(separator: "；")
            return "这次运动暂不和过去比较\(reasons.isEmpty ? "" : "：\(reasons)")。下面只显示本次数据。"
        }
    }

    public static func title(of metric: WorkoutMetric, activity: WorkoutActivityKind) -> String {
        switch metric {
        case .duration: return "运动时长"
        case .distance: return "距离"
        case .averageSpeed: return activity == .cycling ? "运动均速" : "平均配速"
        case .averageHeartRate: return "平均心率"
        case .heartRateZoneDistribution: return "个人心率区间分布"
        case .speedAtHeartRate: return "相同心率下的速度"
        }
    }

    /// 指标数值；`nil` → “--”（不补 0）。
    public static func format(_ value: Double?, metric: WorkoutMetric, activity: WorkoutActivityKind) -> String {
        guard let value, value.isFinite else { return "--" }
        switch metric {
        case .duration: return MetricFormatting.clock(seconds: value)
        case .distance: return MetricFormatting.distance(meters: value)
        case .averageSpeed:
            return activity == .cycling ? "\(MetricFormatting.speedKilometersPerHour(value)) km/h" : pace(metersPerSecond: value)
        case .averageHeartRate: return "\(Int(value.rounded())) 次/分"
        case .heartRateZoneDistribution, .speedAtHeartRate: return "--"
        }
    }

    /// 配速：分'秒" /公里。
    public static func pace(metersPerSecond: Double) -> String {
        guard metersPerSecond.isFinite, metersPerSecond > 0 else { return "--" }
        let perKilometer = Int((1000 / metersPerSecond).rounded())
        let seconds = perKilometer % 60
        return "\(perKilometer / 60)'\(seconds < 10 ? "0" : "")\(seconds)\" /公里"
    }

    /// 单项指标的结论，例如“比最近 4 次平均（19.80 公里）长 8%”。
    public static func comparison(_ item: WorkoutMetricFeedback, activity: WorkoutActivityKind) -> String {
        switch item.outcome {
        case .compared(let average, let difference, let relative, let direction, let baseline):
            let reference = "最近 \(baseline.sampleCount) 次平均（\(format(average, metric: item.metric, activity: activity))）"
            guard direction != .similar else { return "与\(reference)相近" }
            let amount = item.metric == .averageHeartRate
                ? "\(Int(abs(difference).rounded())) 次/分"
                : "\(Int((abs(relative) * 100).rounded()))%"
            return "比\(reference)\(word(for: item.metric, direction: direction, activity: activity)) \(amount)"
        case .insufficientSamples(let found, let required):
            return "可比较的记录还不够（\(found)/\(required) 次），暂不比较"
        case .unavailable(let reason):
            return reason.message
        }
    }

    static func word(for metric: WorkoutMetric, direction: WorkoutFeedbackDirection, activity: WorkoutActivityKind) -> String {
        let higher = direction == .higher
        switch metric {
        case .duration, .distance: return higher ? "长" : "短"
        case .averageSpeed: return higher ? "快" : "慢"
        default: return higher ? "高" : "低"
        }
    }

    /// 未纳入比较的同类运动及原因；没有时为 `nil`。
    public static func exclusionLine(_ feedback: WorkoutFeedback) -> String? {
        guard feedback.excludedCount > 0 else { return nil }
        let reasons = feedback.exclusions.map { "\($0.reason.message)（\($0.count) 次）" }.joined(separator: "；")
        return "另有 \(feedback.excludedCount) 次同类运动没有参与比较：\(reasons)。"
    }

    public static func caveatLines(_ feedback: WorkoutFeedback) -> [String] {
        feedback.caveats.map {
            switch $0 {
            case .deviceNotRecorded: return "部分运动没有记录设备信息，如果中途换过手表，这里可能发现不了。"
            }
        }
    }

    /// 是否显示区间分布这一项。没有个人心率区间时用户在当前设备上无法补救，整项隐藏（不生成默认区间）；
    /// 有区间但样本不足、心率不可比等其他情况照常显示原因。
    public static func showsZoneSection(_ zones: WorkoutZoneFeedback) -> Bool {
        if zones.rows.isEmpty, case .unavailable(.noPersonalZones) = zones.outcome { return false }
        return true
    }

    public static func zoneTitle(_ zone: Int) -> String {
        zone == 0 ? "低于 Z1" : (TrainingZone(rawValue: zone).map { "\($0.title) \($0.name)" } ?? "Z\(zone)")
    }

    /// 区间行，例如“34%（平均 28%）”。
    public static func zoneShare(_ row: WorkoutZoneFeedback.Row) -> String {
        let current = "\(Int((row.currentShare * 100).rounded()))%"
        guard let base = row.baselineShare else { return current }
        return "\(current)（平均 \(Int((base * 100).rounded()))%）"
    }

    /// 区间分布的结论 / 说明。
    public static func zoneSummary(_ zones: WorkoutZoneFeedback) -> String {
        switch zones.outcome {
        case .compared(let baseline):
            return "括号内为最近 \(baseline.sampleCount) 次可比运动的平均占比（使用相同的个人心率区间设置）"
        case .insufficientSamples(let found, let required):
            return "用相同心率区间设置记录的可比运动还不够（\(found)/\(required) 次），只显示本次分布"
        case .unavailable(let reason):
            return reason.message
        }
    }
}
