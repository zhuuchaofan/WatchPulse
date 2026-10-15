import Foundation

/// 一条心率样本（从 HealthKit `HKQuantitySample` 转换而来的平台无关模型）。
public struct HeartRateSample: Identifiable, Hashable, Codable, Sendable {
    /// HealthKit 心率单位 `count/min` 的字符串表示。
    public static let healthKitUnitString = "count/min"

    /// 对应 HealthKit 样本的 UUID。
    public let id: UUID
    /// 心率数值（次/分钟）。
    public let beatsPerMinute: Double
    /// 读取数值时使用的 HealthKit 单位字符串，例如 `count/min`。
    public let unit: String
    /// 采样开始时间。
    public let startDate: Date
    /// 采样结束时间（瞬时样本与 `startDate` 相同）。
    public let endDate: Date
    /// 数据来源（App / 设备）。
    public let source: HealthSampleSource

    public init(
        id: UUID,
        beatsPerMinute: Double,
        unit: String = HeartRateSample.healthKitUnitString,
        startDate: Date,
        endDate: Date,
        source: HealthSampleSource
    ) {
        self.id = id
        self.beatsPerMinute = beatsPerMinute
        self.unit = unit
        self.startDate = startDate
        self.endDate = endDate
        self.source = source
    }

    /// 是否为瞬时样本（开始与结束时间相同）。
    public var isInstantaneous: Bool {
        startDate == endDate
    }
}

/// 样本来源信息，对应 `HKSourceRevision` 与 `HKDevice`。
public struct HealthSampleSource: Hashable, Codable, Sendable {
    /// 是否来自 Apple Watch（`HKDevice.model == "Watch"` 或硬件型号以 `Watch` 开头）。
    public var isAppleWatch: Bool {
        deviceModel == "Watch" || (productType?.hasPrefix("Watch") ?? false)
    }

    /// 来源名称，例如 “Apple Watch”。
    public let name: String
    /// 来源 Bundle ID，例如 `com.apple.health.xxxx`。
    public let bundleIdentifier: String
    /// 来源的硬件型号标识，例如 `Watch6,1`。
    public let productType: String?
    /// 记录该样本的设备名称（`HKDevice.name`）。
    public let deviceName: String?
    /// 记录该样本的设备型号（`HKDevice.model`）。
    public let deviceModel: String?

    public init(
        name: String,
        bundleIdentifier: String,
        productType: String? = nil,
        deviceName: String? = nil,
        deviceModel: String? = nil
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.productType = productType
        self.deviceName = deviceName
        self.deviceModel = deviceModel
    }
}
