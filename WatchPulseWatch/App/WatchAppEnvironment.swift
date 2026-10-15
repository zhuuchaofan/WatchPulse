import Foundation
import WatchKit
import WatchPulseCore
import WatchPulseShared

/// Watch App 的依赖组装。以启动参数 `-WatchPulseDemoMode YES` 启动时使用模拟运动驱动（非真实数据，不写入 HealthKit）。
@MainActor
final class WatchAppEnvironment {
    static let shared = WatchAppEnvironment()

    let isDemoMode: Bool
    let controller: WorkoutSessionController
    /// 心率区间与提醒设置（Watch 本机存储）。
    let zoneStore: HeartRateZoneSettingsStore
    /// 室外骑行 GPS 测速。
    let speedTracker: CyclingSpeedTracker
    /// 目标区间震动提醒（默认关闭）。
    let zoneAlertMonitor: ZoneAlertMonitor
    private let simulatedDriver: SimulatedWorkoutSessionDriver?
    private let simulatedLocation: SimulatedLocationFixProvider?
    private var tickTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        isDemoMode = defaults.bool(forKey: "WatchPulseDemoMode")
        zoneStore = HeartRateZoneSettingsStore(defaults: defaults)
        let locationProvider: any LocationFixProvider
        if isDemoMode {
            let driver = SimulatedWorkoutSessionDriver()
            let location = SimulatedLocationFixProvider()
            simulatedDriver = driver
            simulatedLocation = location
            locationProvider = location
            controller = WorkoutSessionController(driver: driver, sender: nil)
        } else {
            let driver = HealthKitWorkoutSessionDriver()
            simulatedDriver = nil
            simulatedLocation = nil
            locationProvider = CoreLocationFixProvider()
            controller = WorkoutSessionController(driver: driver, sender: driver)
        }
        speedTracker = CyclingSpeedTracker(provider: locationProvider)
        zoneAlertMonitor = ZoneAlertMonitor(store: zoneStore, haptics: WatchHapticPlayer())
        speedTracker.onUpdate = { [weak controller] in controller?.refreshMetrics() }
        controller.addObserver(speedTracker)
        controller.addObserver(zoneAlertMonitor)
        applyZoneSettings()
    }

    /// 区间或提醒设置变化后调用：同步到状态机（随完整状态发给 iPhone）。
    func applyZoneSettings() {
        controller.heartRateZones = zoneStore.zones
        controller.targetZone = zoneStore.activeTargetZone
    }

    /// 每秒推进模拟数据、发送心跳 / 触发慢速重连、刷新速度过期状态。
    func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let now = Date()
                self.simulatedLocation?.advance(to: now)
                self.simulatedDriver?.advance(to: now)
                self.speedTracker.tick()
                self.controller.tick()
            }
        }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        Task { @MainActor in
            let environment = WatchAppEnvironment.shared
            environment.startTicking()
            await environment.controller.recoverIfNeeded()
        }
    }

    /// 系统在运动进行中 App 被终止后重新启动 App 时调用。
    func handleActiveWorkoutRecovery() {
        Task { @MainActor in
            await WatchAppEnvironment.shared.controller.recoverIfNeeded()
        }
    }
}
