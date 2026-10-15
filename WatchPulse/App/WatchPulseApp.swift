import SwiftUI
import WatchPulseCore

@main
struct WatchPulseApp: App {
    @State private var healthOverviewViewModel = HealthOverviewViewModel(
        service: AppDependencies.makeHealthDataService()
    )

    var body: some Scene {
        WindowGroup {
            HealthOverviewView(viewModel: healthOverviewViewModel)
        }
    }
}
