import SwiftUI
import WatchPulseCore

@main
struct WatchPulseApp: App {
    @State private var healthOverviewViewModel: HealthOverviewViewModel

    init() {
        let environment = AppEnvironment.shared
        _healthOverviewViewModel = State(initialValue: HealthOverviewViewModel(service: environment.healthDataService))
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                environment: AppEnvironment.shared,
                healthOverviewViewModel: healthOverviewViewModel
            )
        }
    }
}
