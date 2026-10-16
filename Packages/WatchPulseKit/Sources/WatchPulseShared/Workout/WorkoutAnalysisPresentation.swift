import Foundation

extension HeartRateUsability {
    public var title: String {
        switch self {
        case .unavailable: return "无心率数据"
        case .displayOnly: return "仅可展示"
        case .summary: return "可用于汇总统计"
        case .comparable: return "可用于跨运动比较"
        }
    }
}

/// 把分析结果转成界面可直接显示的说明文字。只描述数据来源、覆盖与限制，不做健康判断。
public enum WorkoutAnalysisPresentation {
    /// 列表 / 详情中的重复状态标签；独立运动返回 `nil`。原始记录始终保留，标签只用于说明。
    public static func duplicateLabel(for workoutID: UUID, in result: WorkoutDeduplicationResult) -> String? {
        for entry in result.entries {
            if entry.mergedDuplicates.contains(where: { $0.id == workoutID }) { return "重复记录" }
            if entry.primary.id == workoutID {
                if !entry.suspectedCounterparts.isEmpty { return "疑似重复" }
                if !entry.mergedDuplicates.isEmpty { return "含 \(entry.mergedDuplicates.count) 个重复来源" }
            }
        }
        return nil
    }

    /// “数据可信度”小节中的心率说明行。第一行为级别，其后为覆盖 / 样本 / 限制原因。
    public static func heartRateLines(_ evidence: HeartRateEvidence) -> [String] {
        var lines = ["心率：\(evidence.usability.title)"]
        guard evidence.rawSampleCount > 0 else {
            return lines + evidence.reasons.map(\.message)
        }
        let coverage = Int((evidence.coverage * 100).rounded())
        var detail = "采样覆盖率 \(coverage)%，有效样本 \(evidence.validSampleCount) 个"
        if evidence.anomalousSampleCount > 0 { detail += "，已排除异常样本 \(evidence.anomalousSampleCount) 个" }
        lines.append(detail)
        lines.append(contentsOf: evidence.reasons.map(\.message))
        return lines
    }

    /// 来源与设备说明。缺失项如实写“未记录”，不推测。
    public static func sourceLines(_ source: WorkoutSourceInfo) -> [String] {
        var lines = ["来源：\(source.name)"]
        let device = [source.deviceName, source.deviceHardwareVersion ?? source.deviceModel]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        lines.append(device.isEmpty ? "设备：未记录" : "设备：\(device.joined(separator: " · "))")
        return lines
    }
}
