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
        // 进步页：最近 4 周趋势与可比运动分析；只为最近的少量运动读取心率。
        _progressViewModel = State(initialValue: WorkoutAnalysisViewModel(
            loader: WorkoutAnalysisLoader(service: environment.workoutHistoryService, maximumHeartRateFetches: 12),
            limit: 200
        ))
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
        }
    }
}
