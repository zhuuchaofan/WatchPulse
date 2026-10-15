import Foundation
import Observation
import WatchPulseShared

/// 心率区间与提醒设置的本地存储（Watch 本机 `UserDefaults`，不依赖 iPhone 连接）。
@MainActor
@Observable
public final class HeartRateZoneSettingsStore {
    public static let zonesKey = "WatchPulse.heartRateZones.v1"
    public static let alertKey = "WatchPulse.zoneAlert.v1"

    /// 用户设置的区间；未设置为 `nil`。
    public private(set) var zones: HeartRateZoneSettings?
    /// 提醒设置。没有区间时 `isEnabled` 始终为 `false`。
    public private(set) var alert: ZoneAlertSettings

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 存储的数据无法解析或不合法时当作未设置，而不是使用任何推算值。
        let zones = defaults.data(forKey: Self.zonesKey).flatMap { try? JSONDecoder().decode(HeartRateZoneSettings.self, from: $0) }
        var alert = defaults.data(forKey: Self.alertKey).flatMap { try? JSONDecoder().decode(ZoneAlertSettings.self, from: $0) }
            ?? ZoneAlertSettings()
        if zones == nil { alert.isEnabled = false }
        self.zones = zones
        self.alert = alert
    }

    /// 开启震动提醒时的目标区间。
    public var activeTargetZone: TrainingZone? {
        zones != nil && alert.isEnabled ? alert.targetZone : nil
    }

    public func save(zones: HeartRateZoneSettings) {
        self.zones = zones
        defaults.set(try? JSONEncoder().encode(zones), forKey: Self.zonesKey)
    }

    /// 恢复为未设置，同时关闭提醒。
    public func resetZones() {
        zones = nil
        defaults.removeObject(forKey: Self.zonesKey)
        var alert = self.alert
        alert.isEnabled = false
        save(alert: alert)
    }

    /// 保存提醒设置。没有区间时不能开启提醒。
    @discardableResult
    public func save(alert newValue: ZoneAlertSettings) -> Bool {
        var value = newValue
        let accepted = !(value.isEnabled && zones == nil)
        if !accepted { value.isEnabled = false }
        alert = value
        defaults.set(try? JSONEncoder().encode(value), forKey: Self.alertKey)
        return accepted
    }
}

/// 目标区间提醒的判定逻辑（纯逻辑）。
///
/// - 只在运动进行中、心率样本新鲜时判断；暂停 / 停止 / 样本过期不提醒并清空计时；
/// - 连续越界至少 `minimumConsecutiveSamples` 个样本且持续 `sustainDuration` 秒才提醒；
/// - 两次提醒至少间隔 `cooldown`；提醒后必须回到区间内 `hysteresisBPM` 以上才会再次提醒，
///   因此持续越界只提醒一次，不会每分钟震动。
public struct ZoneAlertEngine: Sendable {
    public private(set) var lastAlertAt: Date?
    public private(set) var isArmed = true
    private var direction: ZoneHapticKind?
    private var outOfRangeSince: Date?
    private var consecutiveSamples = 0
    private var lastSampleDate: Date?

    public init() {}

    public mutating func evaluate(
        heartRate: Double?,
        sampleDate: Date?,
        phase: WorkoutSessionPhase,
        now: Date,
        zones: HeartRateZoneSettings?,
        settings: ZoneAlertSettings
    ) -> ZoneHapticKind? {
        guard settings.isEnabled, let zones, phase == .running,
              let heartRate, heartRate.isFinite, heartRate > 0,
              let sampleDate, now.timeIntervalSince(sampleDate) <= settings.maximumSampleAge else {
            resetTracking()
            return nil
        }
        let range = zones.range(of: settings.targetZone)
        let lower = Double(range.lowerBound)
        let upper = Double(range.upperBound)
        // 区间很窄时滞回不能超过半宽，否则永远无法重新武装。
        let hysteresis = min(settings.hysteresisBPM, (upper - lower) / 2)

        let current: ZoneHapticKind?
        if heartRate > upper + 0.5 {
            current = .aboveZone
        } else if heartRate < lower - 0.5 {
            current = .belowZone
        } else {
            current = nil
        }

        guard let current else {
            if !isArmed, heartRate >= lower + hysteresis, heartRate <= upper - hysteresis {
                isArmed = true
            }
            resetTracking()
            return nil
        }

        if current != direction {
            direction = current
            outOfRangeSince = sampleDate
            consecutiveSamples = 0
            lastSampleDate = nil
        }
        if sampleDate != lastSampleDate {
            consecutiveSamples += 1
            lastSampleDate = sampleDate
        }
        guard isArmed,
              consecutiveSamples >= settings.minimumConsecutiveSamples,
              let since = outOfRangeSince, sampleDate.timeIntervalSince(since) >= settings.sustainDuration else {
            return nil
        }
        if let lastAlertAt, now.timeIntervalSince(lastAlertAt) < settings.cooldown {
            return nil
        }
        lastAlertAt = now
        isArmed = false
        return current
    }

    private mutating func resetTracking() {
        direction = nil
        outOfRangeSince = nil
        consecutiveSamples = 0
        lastSampleDate = nil
    }
}

/// Watch 端目标区间提醒：观察每条心率指标，按 `ZoneAlertEngine` 判定后播放震动。默认关闭。
@MainActor
@Observable
public final class ZoneAlertMonitor: WorkoutLiveObserver {
    /// 最近一次提醒（界面显示用）。
    public private(set) var lastAlert: (kind: ZoneHapticKind, date: Date)?
    public private(set) var alertCount = 0

    @ObservationIgnored private let store: HeartRateZoneSettingsStore
    @ObservationIgnored private let haptics: any HapticPlaying
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var engine = ZoneAlertEngine()
    @ObservationIgnored private var phase: WorkoutSessionPhase = .notStarted

    public init(store: HeartRateZoneSettingsStore, haptics: any HapticPlaying, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.haptics = haptics
        self.now = now
    }

    public func workoutDidStart(_ configuration: WorkoutConfigurationRequest, at date: Date) {
        engine = ZoneAlertEngine()
        lastAlert = nil
        alertCount = 0
        phase = .prepared
    }

    public func workoutPhaseDidChange(to phase: WorkoutSessionPhase, at date: Date) {
        self.phase = phase
    }

    public func workoutMetricsWillPublish(_ metrics: WorkoutMetricsSnapshot) -> WorkoutMetricsSnapshot {
        let kind = engine.evaluate(
            heartRate: metrics.heartRateBPM,
            sampleDate: metrics.timestamp,
            phase: phase,
            now: now(),
            zones: store.zones,
            settings: store.alert
        )
        if let kind {
            lastAlert = (kind, now())
            alertCount += 1
            haptics.play(kind)
        }
        return metrics
    }

    public func workoutDidEnd() {
        phase = .stopped
    }
}

/// 记录震动调用（测试与演示模式）。
@MainActor
public final class RecordingHapticPlayer: HapticPlaying {
    public private(set) var played: [ZoneHapticKind] = []
    public init() {}
    public func play(_ kind: ZoneHapticKind) { played.append(kind) }
}
