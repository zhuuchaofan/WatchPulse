import SwiftUI
import WatchPulseCore

struct RootView: View {
    let environment: AppEnvironment
    let healthOverviewViewModel: HealthOverviewViewModel

    var body: some View {
        TabView {
            HealthOverviewView(
                viewModel: healthOverviewViewModel,
                service: environment.healthDataService
            )
            .tabItem { Label("健康", systemImage: "heart.text.square") }

            WorkoutHomeView(
                monitor: environment.liveWorkoutMonitor,
                simulatedWorkout: environment.simulatedWorkout
            )
            .tabItem { Label("运动", systemImage: "figure.run") }
        }
    }
}
