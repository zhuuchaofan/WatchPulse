import Foundation
import WatchPulseShared

/// 骑行码表的显示内容（Watch 与 iPhone 共用，纯逻辑便于测试）。
///
/// 规则：速度缺失、过期、暂停、未授权、连接中断时一律显示 `--` 并说明原因，**不显示 0**；
/// 只有可信的静止（有效 GPS 读数为 0）才显示 0.0。
public struct CyclingDisplayModel: Hashable, Sendable {
    public let speedText: String
    /// 速度来源与状态，例如“GPS 有效 · 2秒前”“信号丢失”。
    public let speedStatusText: String
    /// 速度是否为可信的实时值（界面据此决定是否高亮）。
    public let isSpeedLive: Bool
    public let averageSpeedText: String
    public let distanceText: String
    public let heartRateText: String
    public let zone: TrainingZone?
    /// 例如“Z3 有氧”“低于 Z1”“未设置心率区间”。
    public let zoneText: String
    public let targetZone: TrainingZone?
    public let zones: HeartRateZoneSettings?

    /// 速度读数超过此时长（秒）未更新即视为过期。
    public static let maximumSpeedAge: TimeInterval = 10

    /// - Parameter isLinkHealthy: 数据链路是否正常（iPhone 端为“已连接”；Watch 本机始终为 `true`）。
    public init(
        configuration: WorkoutConfigurationRequest?,
        metrics: WorkoutMetricsSnapshot?,
        phase: WorkoutSessionPhase,
        zones: HeartRateZoneSettings?,
        targetZone: TrainingZone?,
        isLinkHealthy: Bool,
        now: Date
    ) {
        self.zones = zones
        self.targetZone = targetZone

        let speed = metrics?.speed
        if phase == .paused {
            speedText = "--"
            speedStatusText = "已暂停"
            isSpeedLive = false
        } else if !isLinkHealthy {
            speedText = "--"
            speedStatusText = "连接中断"
            isSpeedLive = false
        } else if let speed {
            let age = speed.sampleDate.map { max(0, now.timeIntervalSince($0)) }
            if speed.quality.hasValue, let value = speed.metersPerSecond, let age, age <= Self.maximumSpeedAge {
                speedText = MetricFormatting.speedKilometersPerHour(value)
                let accuracy = speed.quality == .lowAccuracy ? "精度低" : "有效"
                speedStatusText = "\(speed.source.title) \(accuracy) · \(Int(age.rounded()))秒前"
                isSpeedLive = true
            } else {
                speedText = "--"
                speedStatusText = speed.quality.hasValue ? SpeedQuality.stale.title : speed.quality.title
                isSpeedLive = false
            }
        } else {
            speedText = "--"
            if let configuration, configuration.activity == .cycling, configuration.location != .outdoor {
                speedStatusText = "室内骑行无 GPS 速度"
            } else {
                speedStatusText = "等待速度数据"
            }
            isSpeedLive = false
        }

        averageSpeedText = MetricFormatting.speedKilometersPerHour(metrics?.averageSpeedMetersPerSecond)
        distanceText = metrics?.distanceMeters.map(MetricFormatting.distance(meters:)) ?? "--"

        if let heartRate = metrics?.heartRateBPM, heartRate.isFinite, heartRate > 0 {
            heartRateText = "\(Int(heartRate.rounded()))"
            if let zones {
                let zone = zones.zone(for: heartRate)
                self.zone = zone
                zoneText = zone.map { "\($0.title) \($0.name)" } ?? "低于 \(TrainingZone.z1.title)"
            } else {
                zone = nil
                zoneText = "未设置心率区间"
            }
        } else {
            heartRateText = "--"
            zone = nil
            zoneText = zones == nil ? "未设置心率区间" : "等待心率"
        }
    }
}
