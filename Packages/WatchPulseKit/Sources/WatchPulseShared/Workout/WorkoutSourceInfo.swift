import Foundation

/// 运动记录的来源与设备信息，用于去重与可比较性判断。
///
/// 全部字段都来自 HealthKit 元数据，缺失时为 `nil`；缺失不被当作“相同”，
/// 因此信息不全只会让判定更保守（独立 / 疑似），不会导致误判重复。
public struct WorkoutSourceInfo: Hashable, Codable, Sendable {
    public let name: String
    /// 来源 App 的 bundle 标识（`HKSource.bundleIdentifier`）。
    public let bundleIdentifier: String?
    /// 设备名称、型号与硬件版本（`HKDevice`）。
    public let deviceName: String?
    public let deviceModel: String?
    public let deviceHardwareVersion: String?
    /// 写入方提供的外部标识（`HKMetadataKeyExternalUUID`）。
    public let externalIdentifier: String?
    /// 同步标识（`HKMetadataKeySyncIdentifier`）。
    public let syncIdentifier: String?

    public init(
        name: String,
        bundleIdentifier: String? = nil,
        deviceName: String? = nil,
        deviceModel: String? = nil,
        deviceHardwareVersion: String? = nil,
        externalIdentifier: String? = nil,
        syncIdentifier: String? = nil
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.deviceHardwareVersion = deviceHardwareVersion
        self.externalIdentifier = externalIdentifier
        self.syncIdentifier = syncIdentifier
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// 来源标识：优先 bundle，其次名称。
    public var sourceKey: String {
        Self.normalized(bundleIdentifier).map { "bundle:\($0)" }
            ?? "name:\(Self.normalized(name)?.lowercased() ?? "")"
    }

    /// 可靠的重复标识（外部 UUID 或同步标识，非空）。
    public var duplicateKeys: [String] {
        var keys: [String] = []
        if let value = Self.normalized(externalIdentifier) { keys.append("external:\(value)") }
        if let value = Self.normalized(syncIdentifier) { keys.append("sync:\(value)") }
        return keys
    }

    /// 物理设备标识：名称、型号、硬件版本三者齐全才有效。
    public var deviceKey: String? {
        guard let name = Self.normalized(deviceName),
              let model = Self.normalized(deviceModel),
              let hardware = Self.normalized(deviceHardwareVersion) else { return nil }
        return "\(name)|\(model)|\(hardware)"
    }

    /// 设备型号族（用于可比较性：传感器与算法一致）。硬件版本优先，其次型号；都没有则未知。
    public var deviceFamilyKey: String? {
        Self.normalized(deviceHardwareVersion) ?? Self.normalized(deviceModel)
    }

    /// 是否为 Apple 原生「体能训练」来源。
    public var isAppleNative: Bool {
        guard let bundle = Self.normalized(bundleIdentifier) else { return false }
        return bundle.hasPrefix("com.apple.health") || bundle == "com.apple.Fitness"
    }
}

extension WorkoutRecord {
    /// 来源信息；旧数据只有名称时退回名称。
    public var source: WorkoutSourceInfo {
        sourceInfo ?? WorkoutSourceInfo(name: sourceName)
    }
}
