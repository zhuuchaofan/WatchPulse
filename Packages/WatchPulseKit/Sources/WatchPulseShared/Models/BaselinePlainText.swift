import Foundation

extension BaselineComparison {
    /// 卡片上的一句话：不出现“基线”等术语。例如“比平时高 3”“和平时差不多”。
    /// 数据不足时不给出差值，也不说成与平时一样。
    public var plainShortText: String {
        switch sufficiency {
        case .insufficient:
            return "还在了解你的平时水平"
        case .sufficient:
            guard let delta, let direction else { return "" }
            if direction == .flat { return "和平时差不多" }
            return "比平时\(direction == .up ? "高" : "低") \(kind.formattedValue(abs(delta)))"
        }
    }
}
