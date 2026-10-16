import SwiftUI
import WatchPulseCore

@main
struct WatchPulseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var healthOverviewViewModel: HealthOverviewViewModel
    @State private var insightsViewModel: HealthInsightsViewModel
    @State private var goalsViewModel: WorkoutGoalsViewModel
    @State private var progressViewModel: WorkoutAnalysisViewModel

    init() {
        let environment = AppEnvironment.shared
        _healthOverviewViewModel = State(initialValue: HealthOverviewViewModel(service: environment.healthDataService))
        _insightsViewModel = State(initialValue: HealthInsightsViewModel(service: environment.healthDataService))
        _goalsViewModel = State(initialValue: WorkoutGoalsViewModel(
            store: environment.workoutGoalStore,
            service: environment.workoutHistoryService
        ))
        // 进步页：最近 4 周趋势只用次数 / 时长 / 距离，不读心率；最近一次运动的对比由页面单独读取（与运动页一致）。
        _progressViewModel = State(initialValue: WorkoutAnalysisViewModel(
            loader: WorkoutAnalysisLoader(service: environment.workoutHistoryService, maximumHeartRateFetches: 0),
            limit: 200
        ))
    }

    /// 仅演示模式：`-WatchPulseAppearance dark|light` 固定外观，供 CI 截图覆盖深色模式。真实模式始终跟随系统。
    private static var demoColorScheme: ColorScheme? {
        guard AppEnvironment.shared.isDemoMode else { return nil }
        switch UserDefaults.standard.string(forKey: "WatchPulseAppearance") {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                environment: AppEnvironment.shared,
                healthOverviewViewModel: healthOverviewViewModel,
                insightsViewModel: insightsViewModel,
                goalsViewModel: goalsViewModel,
                progressViewModel: progressViewModel
            )
            .preferredColorScheme(Self.demoColorScheme)
        }
    }
}
