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
    private let simulatedDriver: SimulatedWorkoutSessionDriver?
    private var tickTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        isDemoMode = defaults.bool(forKey: "WatchPulseDemoMode")
        if isDemoMode {
            let driver = SimulatedWorkoutSessionDriver()
            simulatedDriver = driver
            controller = WorkoutSessionController(driver: driver, sender: nil)
        } else {
            let driver = HealthKitWorkoutSessionDriver()
            simulatedDriver = nil
            controller = WorkoutSessionController(driver: driver, sender: driver)
        }
    }

    /// 每秒推进模拟数据、发送心跳 / 触发慢速重连。
    func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.simulatedDriver?.advance(to: Date())
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
