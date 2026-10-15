import SwiftUI
import WatchPulseCore

struct RootView: View {
    let environment: AppEnvironment
    let healthOverviewViewModel: HealthOverviewViewModel
    let insightsViewModel: HealthInsightsViewModel

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            HealthOverviewView(
                viewModel: healthOverviewViewModel,
                service: environment.healthDataService
            )
            .tabItem { Label("健康", systemImage: "heart.text.square") }

            WorkoutHomeView(
                monitor: environment.liveWorkoutMonitor,
                simulatedWorkout: environment.simulatedWorkout,
                historyService: environment.workoutHistoryService,
                onSimulatedWorkoutCompleted: environment.recordSimulatedWorkout
            )
            .tabItem { Label("运动", systemImage: "figure.run") }

            InsightsView(viewModel: insightsViewModel, service: environment.healthDataService)
                .tabItem { Label("分析", systemImage: "chart.line.text.clipboard") }
        }
        .onChange(of: scenePhase) { _, phase in
            // 后台期间计时器暂停；回到前台立即检查一次连接是否已超时。
            if phase == .active {
                environment.liveWorkoutMonitor.evaluateConnection()
            }
        }
    }
}
