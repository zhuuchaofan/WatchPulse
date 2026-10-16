import SwiftUI
import WatchPulseCore

@main
struct WatchPulseApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var healthOverviewViewModel: HealthOverviewViewModel
    @State private var insightsViewModel: HealthInsightsViewModel
    @State private var goalsViewModel: WorkoutGoalsViewModel

    init() {
        let environment = AppEnvironment.shared
        _healthOverviewViewModel = State(initialValue: HealthOverviewViewModel(service: environment.healthDataService))
        _insightsViewModel = State(initialValue: HealthInsightsViewModel(service: environment.healthDataService))
        _goalsViewModel = State(initialValue: WorkoutGoalsViewModel(
            store: environment.workoutGoalStore,
            service: environment.workoutHistoryService
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                environment: AppEnvironment.shared,
                healthOverviewViewModel: healthOverviewViewModel,
                insightsViewModel: insightsViewModel,
                goalsViewModel: goalsViewModel
            )
        }
    }
}
