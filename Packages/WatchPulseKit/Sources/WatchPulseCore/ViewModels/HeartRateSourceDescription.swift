import Foundation
import WatchPulseShared

/// 把心率样本的 HealthKit 来源字段翻译成用户看得懂的“数据详情”。
///
/// HealthKit 原始字段对普通用户没有意义甚至互相矛盾：
/// - `source.name` 对 Apple Watch 来说是用户给手表起的名字（可以是任何名字，例如 “HUAWEI Watch”）；
/// - `deviceName` / `deviceModel` 通常是 “Apple Watch” / “Watch”；
/// - `productType` 是硬件代码（例如 `Watch6,15`）；`bundleIdentifier` 是 `com.apple.health.<UUID>`。
/// 这里只输出型号、名称、记录方式三类可读信息，不展示 Bundle ID 与单位字符串。
public struct HeartRateSourceDescription: Equatable, Sendable {
    /// 设备型号，例如 “Apple Watch Series 8”；没有设备信息时为 nil。
    public let deviceModel: String?
    /// 用户给手表起的名字；与型号相同或没有意义时为 nil。
    public let customName: String?
    /// 这条数据是怎么来的，例如 “手表自动测量，同步到「健康」App”。
    public let recordedBy: String

    public init(source: HealthSampleSource) {
        let isSimulated = source.name == SimulatedHealthData.sourceName
        if isSimulated {
            deviceModel = nil
            customName = nil
            recordedBy = "示例数据，不是真实测量"
            return
        }

        if source.isAppleWatch {
            let model = Self.appleWatchModelName(productType: source.productType)
            deviceModel = model
            let name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            customName = Self.isMeaningfulCustomName(name, model: model) ? name : nil
            recordedBy = Self.isHealthSystemSource(source.bundleIdentifier)
                ? "手表自动测量，同步到「健康」App"
                : "由「\(source.name)」写入「健康」App"
            return
        }

        let parts = [source.deviceName, source.deviceModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var unique: [String] = []
        for part in parts where !unique.contains(part) {
            unique.append(part)
        }
        deviceModel = unique.isEmpty ? nil : unique.joined(separator: " ")
        customName = nil
        recordedBy = "由「\(source.name)」写入「健康」App"
    }

    /// Apple Watch 硬件代码 → 市售型号。未知代码（例如更新的机型）统一显示 “Apple Watch”。
    public static func appleWatchModelName(productType: String?) -> String {
        guard let productType, productType.hasPrefix("Watch") else { return "Apple Watch" }
        let code = productType.dropFirst("Watch".count).split(separator: ",")
        guard code.count == 2, let major = Int(code[0]), let minor = Int(code[1]) else { return "Apple Watch" }
        let name: String?
        switch (major, minor) {
        case (1, _): name = "Apple Watch（第一代）"
        case (2, 6...7): name = "Apple Watch Series 1"
        case (2, 3...4): name = "Apple Watch Series 2"
        case (3, 1...4): name = "Apple Watch Series 3"
        case (4, 1...4): name = "Apple Watch Series 4"
        case (5, 1...4): name = "Apple Watch Series 5"
        case (5, 9...12): name = "Apple Watch SE"
        case (6, 1...4): name = "Apple Watch Series 6"
        case (6, 6...9): name = "Apple Watch Series 7"
        case (6, 10...13): name = "Apple Watch SE（第二代）"
        case (6, 14...17): name = "Apple Watch Series 8"
        case (6, 18): name = "Apple Watch Ultra"
        case (7, 1...4): name = "Apple Watch Series 9"
        case (7, 5): name = "Apple Watch Ultra 2"
        case (7, 8...11): name = "Apple Watch Series 10"
        default: name = nil
        }
        return name ?? "Apple Watch"
    }

    /// Apple Watch 自身写入的数据，来源 Bundle ID 形如 `com.apple.health.<UUID>`。
    static func isHealthSystemSource(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier.hasPrefix("com.apple.health")
    }

    /// 名字为空或只是 “Apple Watch” / 型号本身时，不必单独再展示一次。
    private static func isMeaningfulCustomName(_ name: String, model: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name != model && name != "Apple Watch"
    }
}
