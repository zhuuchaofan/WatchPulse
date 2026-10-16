import Foundation

/// 日常健康监控的指标类型。
public enum HealthMetricKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case heartRate
    case heartRateVariability
    case restingHeartRate
    case stepCount
    case activeEnergy
    case sleep

    /// 数据在一天内的聚合方式。
    public enum Aggregation: Sendable {
        /// 离散值（取最新值 / 日均值、最小、最大）。
        case discrete
        /// 累计值（取当日总和）。
        case cumulative
        /// 睡眠（按夜聚合时长）。
        case sleep
    }

    public var id: String { rawValue }

    public var aggregation: Aggregation {
        switch self {
        case .heartRate, .heartRateVariability, .restingHeartRate:
            return .discrete
        case .stepCount, .activeEnergy:
            return .cumulative
        case .sleep:
            return .sleep
        }
    }

    public var title: String {
        switch self {
        case .heartRate: return "心率"
        case .heartRateVariability: return "心率变异性"
        case .restingHeartRate: return "静息心率"
        case .stepCount: return "步数"
        case .activeEnergy: return "活动能量"
        case .sleep: return "睡眠"
        }
    }

    /// 不常见概念首次出现时的一句话解释；常见指标为 `nil`。
    public var explanation: String? {
        switch self {
        case .heartRateVariability:
            return "心率变异性（HRV）是相邻两次心跳间隔的变化幅度，由 Apple Watch 在你安静时测量。不同人差别很大，只适合和自己过去比较。"
        case .restingHeartRate:
            return "静息心率是你安静休息时的心率，由 Apple Watch 在日常佩戴中估算。"
        case .heartRate, .stepCount, .activeEnergy, .sleep:
            return nil
        }
    }

    /// 数值单位（展示用）。
    public var unitLabel: String {
        switch self {
        case .heartRate, .restingHeartRate: return "次/分"
        case .heartRateVariability: return "毫秒"
        case .stepCount: return "步"
        case .activeEnergy: return "千卡"
        case .sleep: return "小时"
        }
    }

    /// 摘要卡片上数值的含义。
    public var summaryCaption: String {
        switch self {
        case .heartRate, .heartRateVariability, .restingHeartRate: return "最新"
        case .stepCount, .activeEnergy: return "今日累计"
        case .sleep: return "昨晚"
        }
    }

    /// 趋势图中每日数值的含义。
    public var trendCaption: String {
        switch aggregation {
        case .discrete: return "日均"
        case .cumulative: return "每日合计"
        case .sleep: return "每晚睡眠"
        }
    }

    public var systemImage: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .heartRateVariability: return "waveform.path.ecg"
        case .restingHeartRate: return "heart.circle"
        case .stepCount: return "figure.walk"
        case .activeEnergy: return "flame.fill"
        case .sleep: return "bed.double.fill"
        }
    }

    /// 只格式化数值部分（不含单位）。睡眠的数值单位为小时。
    public func formattedValue(_ value: Double) -> String {
        switch self {
        case .heartRate, .restingHeartRate, .heartRateVariability, .activeEnergy:
            return MetricFormatting.grouped(Int(value.rounded()))
        case .stepCount:
            return MetricFormatting.grouped(Int(value.rounded()))
        case .sleep:
            return MetricFormatting.duration(hours: value)
        }
    }

    /// 数值 + 单位，例如 “72 次/分”、“7小时12分”。
    public func formattedValueWithUnit(_ value: Double) -> String {
        switch self {
        case .sleep:
            return formattedValue(value)
        default:
            return "\(formattedValue(value)) \(unitLabel)"
        }
    }
}

/// 与区域设置无关的简单格式化，保证各平台输出一致、便于测试。
public enum MetricFormatting {
    /// 千分位分组：8234 → "8,234"。
    public static func grouped(_ value: Int) -> String {
        let digits = String(abs(value))
        var result = ""
        for (index, character) in digits.reversed().enumerated() {
            if index > 0, index % 3 == 0 {
                result.append(",")
            }
            result.append(character)
        }
        return (value < 0 ? "-" : "") + String(result.reversed())
    }

    /// 小时数 → “7小时12分”。
    public static func duration(hours: Double) -> String {
        duration(seconds: hours * 3600)
    }

    /// 秒数 → “1小时05分” / “42分” / “0分”。
    public static func duration(seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return "\(minutes)分"
        }
        return "\(hours)小时" + (minutes < 10 ? "0" : "") + "\(minutes)分"
    }

    /// 计时器格式：“1:02:03” / “12:05”。
    public static func clock(seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        if hours > 0 {
            return "\(hours):\(pad(minutes)):\(pad(secs))"
        }
        return "\(pad(minutes)):\(pad(secs))"
    }

    /// 距离（米）→ “3.25 公里” / “820 米”。
    public static func distance(meters: Double) -> String {
        if meters >= 1000 {
            let kilometers = (meters / 10).rounded() / 100
            return "\(twoDecimals(kilometers)) 公里"
        }
        return "\(Int(meters.rounded())) 米"
    }

    private static func twoDecimals(_ value: Double) -> String {
        let hundredths = Int((value * 100).rounded())
        let whole = hundredths / 100
        let fraction = hundredths % 100
        return "\(whole)." + (fraction < 10 ? "0" : "") + "\(fraction)"
    }
}
