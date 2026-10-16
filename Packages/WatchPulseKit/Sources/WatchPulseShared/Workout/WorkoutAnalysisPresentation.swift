import Foundation

extension HeartRateUsability {
    public var title: String {
        switch self {
        case .unavailable: return "没有心率数据"
        case .displayOnly: return "仅供参考"
        case .summary: return "可用于平均值统计"
        case .comparable: return "可与过去的运动比较"
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

    /// “数据可信度”小节默认显示的一句话结论（通俗说明能做什么、不能做什么）。
    /// 级别只代表覆盖率等达到了门槛（例如可比较要求覆盖约 80%），不代表记录“完整”；具体原因见详情。
    /// 覆盖率、样本数等技术依据见 `heartRateLines`，放在可展开的详情中。
    public static func heartRateSummary(_ evidence: HeartRateEvidence) -> String {
        switch evidence.usability {
        case .comparable:
            return "这次心率记录较充分，可以用于和过去的运动比较。"
        case .summary:
            return "这次心率记录可以用来看平均心率，但还不符合和过去运动比较的条件。"
        case .displayOnly:
            return "这次心率记录不符合统计和比较的条件，曲线仅供参考。具体原因见下方判断依据。"
        case .unavailable:
            return evidence.reasons.contains(.notLoaded)
                ? "这次运动的心率数据没有读取成功，暂时无法判断。"
                : "这次运动没有可用的心率数据。"
        }
    }

    /// “数据可信度”详情中的心率说明行。第一行为级别，其后为覆盖 / 样本 / 限制原因。
    public static func heartRateLines(_ evidence: HeartRateEvidence) -> [String] {
        var lines = ["心率：\(evidence.usability.title)"]
        guard evidence.rawSampleCount > 0 else {
            return lines + evidence.reasons.map(\.message)
        }
        let coverage = Int((evidence.coverage * 100).rounded())
        var detail = "运动期间有心率记录的时间占 \(coverage)%，有效心率点 \(evidence.validSampleCount) 个"
        if evidence.anomalousSampleCount > 0 { detail += "，已排除明显异常的 \(evidence.anomalousSampleCount) 个" }
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
