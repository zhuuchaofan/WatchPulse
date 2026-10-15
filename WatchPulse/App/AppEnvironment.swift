import Foundation
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

    init(defaults: UserDefaults = .standard) {
        isDemoMode = defaults.bool(forKey: Self.demoModeKey)
        if isDemoMode {
            healthDataService = MockHealthDataService.demo()
        } else {
            healthDataService = HealthKitHealthDataService()
        }
    }
}
