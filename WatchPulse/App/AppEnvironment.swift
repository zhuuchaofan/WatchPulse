import Foundation
import UIKit
import WatchPulseCore
import WatchPulseShared

/// 组装依赖的唯一入口。
///
/// 默认使用真实 HealthKit；以启动参数 `-WatchPulseDemoMode YES` 启动时进入**演示模式**，
/// 所有数据都来自模拟实现，界面会显示“演示模式 · 模拟数据”横幅。演示模式用于 UI 测试与无真机时的界面验证，
/// 不能作为真机验收依据。
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    static let demoModeKey = "WatchPulseDemoMode"

    let isDemoMode: Bool
    let healthDataService: any HealthDataService
    let liveWorkoutMonitor: LiveWorkoutMonitor
    /// 演示模式下的模拟 Watch 运动。
    let simulatedWorkout: SimulatedMirroredWorkout?
    private let mirroringReceiver: HealthKitMirroringReceiver?

    init(defaults: UserDefaults = .standard) {
        isDemoMode = defaults.bool(forKey: Self.demoModeKey)
        if isDemoMode {
            healthDataService = MockHealthDataService.demo()
            liveWorkoutMonitor = LiveWorkoutMonitor(dataOrigin: .simulated)
            simulatedWorkout = SimulatedMirroredWorkout(monitor: liveWorkoutMonitor)
            mirroringReceiver = nil
        } else {
            healthDataService = HealthKitHealthDataService()
            liveWorkoutMonitor = LiveWorkoutMonitor(dataOrigin: .healthKit)
            simulatedWorkout = nil
            mirroringReceiver = HealthKitMirroringReceiver(monitor: liveWorkoutMonitor)
        }
    }

    /// 在 App 启动早期调用，注册镜像会话回调。
    func startWorkoutMirroring() {
        mirroringReceiver?.start()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MainActor.assumeIsolated {
            AppEnvironment.shared.startWorkoutMirroring()
        }
        return true
    }
}
