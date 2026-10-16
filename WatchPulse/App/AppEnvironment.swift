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
    /// 演示场景：`-WatchPulseDemoScenario full|empty|failure|needsAuthorization|insufficient`，用于 UI 测试覆盖各种状态。
    static let demoScenarioKey = "WatchPulseDemoScenario"

    let isDemoMode: Bool
    let healthDataService: any HealthDataService
    let workoutHistoryService: any WorkoutHistoryService
    let liveWorkoutMonitor: LiveWorkoutMonitor
    /// 个人运动目标：真实模式存于本机 `UserDefaults`；演示模式只在内存中，不写入磁盘。
    let workoutGoalStore: any WorkoutGoalStore
    /// 演示模式下的模拟 Watch 运动。
    let simulatedWorkout: SimulatedMirroredWorkout?
    private let mirroringReceiver: HealthKitMirroringReceiver?

    init(defaults: UserDefaults = .standard) {
        isDemoMode = defaults.bool(forKey: Self.demoModeKey)
        if isDemoMode {
            let scenario = DemoScenario(rawValue: defaults.string(forKey: Self.demoScenarioKey) ?? "") ?? .full
            healthDataService = scenario.makeHealthDataService()
            workoutHistoryService = scenario.makeWorkoutHistoryService()
            liveWorkoutMonitor = LiveWorkoutMonitor(dataOrigin: .simulated)
            workoutGoalStore = InMemoryWorkoutGoalStore()
            simulatedWorkout = SimulatedMirroredWorkout(monitor: liveWorkoutMonitor)
            mirroringReceiver = nil
        } else {
            healthDataService = HealthKitHealthDataService()
            workoutHistoryService = HealthKitWorkoutHistoryService()
            liveWorkoutMonitor = LiveWorkoutMonitor(dataOrigin: .healthKit)
            workoutGoalStore = UserDefaultsWorkoutGoalStore(defaults: defaults)
            simulatedWorkout = nil
            mirroringReceiver = HealthKitMirroringReceiver(monitor: liveWorkoutMonitor)
        }
    }

    /// 演示模式：把刚结束的模拟运动加入模拟历史（真实模式下运动由 Apple Watch 写入 HealthKit）。
    func recordSimulatedWorkout(_ workout: WorkoutRecord, heartRates: [HeartRatePoint]) {
        (workoutHistoryService as? MockWorkoutHistoryService)?.insert(workout, heartRates: heartRates)
    }

    /// 在 App 启动早期调用：注册镜像会话回调，并启动与页面无关的连接看门狗。
    func startWorkoutMirroring() {
        mirroringReceiver?.start()
        liveWorkoutMonitor.startConnectionWatchdog()
    }
}

/// 演示模式下的数据场景（全部为模拟数据）。
enum DemoScenario: String {
    case full
    case empty
    case failure
    case needsAuthorization
    /// 只有最近 10 天的静息心率 / HRV、3 晚睡眠：基线“积累中”。
    case insufficient
    /// 40 次混合类型的运动：同类历史超出最近 12 条，用于核对各页对最近一次运动的比较一致。
    case longHistory

    func makeHealthDataService() -> any HealthDataService {
        switch self {
        case .full:
            return MockHealthDataService.demo()
        case .empty:
            return MockHealthDataService()
        case .failure:
            let error = HealthDataError.protectedDataUnavailable
            var summaries: [HealthMetricKind: MockHealthDataService.Behavior<MetricSummaryValue>] = [:]
            for kind in HealthMetricKind.allCases {
                summaries[kind] = .failure(error)
            }
            var trends: [HealthMetricKind: MockHealthDataService.Behavior<[MetricDataPoint]>] = [:]
            for kind in HealthMetricKind.allCases {
                trends[kind] = .failure(error)
            }
            return MockHealthDataService(fetchBehavior: .failure(error), summaries: summaries, trends: trends, sleepNights: .failure(error))
        case .needsAuthorization:
            let service = MockHealthDataService.demo()
            service.authorizationStatus = .shouldRequest
            return service
        case .longHistory:
            return MockHealthDataService.demo()
        case .insufficient:
            let service = MockHealthDataService.demo()
            let data = SimulatedHealthData(now: Date())
            for kind in [HealthMetricKind.restingHeartRate, .heartRateVariability] {
                service.setTrend(.value(data.trend(for: kind, days: 10)), for: kind)
            }
            service.setSleepNights(.value(data.sleepNights(days: 3)))
            return service
        }
    }

    func makeWorkoutHistoryService() -> any WorkoutHistoryService {
        switch self {
        case .full, .needsAuthorization, .insufficient:
            return MockWorkoutHistoryService.demo()
        case .longHistory:
            return MockWorkoutHistoryService.demo(count: 40)
        case .empty:
            return MockWorkoutHistoryService()
        case .failure:
            return MockWorkoutHistoryService(workouts: .failure(.protectedDataUnavailable))
        }
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
