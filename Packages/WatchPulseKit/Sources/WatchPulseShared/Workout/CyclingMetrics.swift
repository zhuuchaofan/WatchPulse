import Foundation

/// 速度数据来源。v0.2 只实现 GPS；`sensor`（蓝牙速度传感器）为后续扩展预留。
public enum SpeedSource: String, Hashable, Codable, Sendable {
    case gps
    case sensor
    case unavailable

    public var title: String {
        switch self {
        case .gps: return "GPS"
        case .sensor: return "传感器"
        case .unavailable: return "不可用"
        }
    }

    /// 对端（更新版本 App）发来未知取值时降级为 `.unavailable`，不能让整条消息解码失败。
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SpeedSource(rawValue: raw) ?? .unavailable
    }
}

/// 速度数据的质量。只有 `good` / `lowAccuracy` 时才有数值；其余状态界面显示 `--`，**不能当作 0**。
public enum SpeedQuality: String, Hashable, Codable, Sendable {
    /// 精度足够、数据新鲜。
    case good
    /// 有数值但定位 / 速度精度较差，界面需标注。
    case lowAccuracy
    /// 一段时间没有有效定位，旧数值已过期。
    case stale
    /// 还没有有效定位、GPS 不可用或不适用（例如室内）。
    case unavailable
    /// 用户未授权定位。
    case notAuthorized
    /// 运动暂停中。
    case paused

    /// 是否可以展示数值。
    public var hasValue: Bool { self == .good || self == .lowAccuracy }

    public var title: String {
        switch self {
        case .good: return "有效"
        case .lowAccuracy: return "精度低"
        case .stale: return "信号丢失"
        case .unavailable: return "无定位"
        case .notAuthorized: return "未授权定位"
        case .paused: return "已暂停"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SpeedQuality(rawValue: raw) ?? .unavailable
    }
}

/// 某一时刻的速度读数（已经过滤 / 平滑）。随 `WorkoutMetricsSnapshot` 一起镜像到 iPhone。
public struct WorkoutSpeedSample: Hashable, Codable, Sendable {
    /// 米 / 秒。只有 `quality.hasValue` 时才非 `nil`。
    public let metersPerSecond: Double?
    /// 最近一次被采用的定位样本时间；没有时为 `nil`。
    public let sampleDate: Date?
    public let source: SpeedSource
    public let quality: SpeedQuality

    public init(metersPerSecond: Double?, sampleDate: Date?, source: SpeedSource, quality: SpeedQuality) {
        // 质量不允许展示时强制不带数值，避免下游把过期 / 无效数据当真。
        self.metersPerSecond = quality.hasValue ? metersPerSecond : nil
        self.sampleDate = sampleDate
        self.source = source
        self.quality = quality
    }

    /// 没有可用速度。
    public static func unavailable(_ quality: SpeedQuality, source: SpeedSource = .unavailable, sampleDate: Date? = nil) -> WorkoutSpeedSample {
        WorkoutSpeedSample(metersPerSecond: nil, sampleDate: sampleDate, source: source, quality: quality)
    }

    /// 千米 / 时（显示用）。
    public var kilometersPerHour: Double? {
        metersPerSecond.map { $0 * 3.6 }
    }
}

extension MetricFormatting {
    /// 速度（米 / 秒）→ “26.8”（千米 / 时，一位小数）；`nil` → “--”。
    public static func speedKilometersPerHour(_ metersPerSecond: Double?) -> String {
        guard let metersPerSecond, metersPerSecond.isFinite, metersPerSecond >= 0 else { return "--" }
        let tenths = Int((metersPerSecond * 36).rounded())
        return "\(tenths / 10).\(tenths % 10)"
    }
}
