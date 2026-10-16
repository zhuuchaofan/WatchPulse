import SwiftUI
import WatchPulseCore

struct RootView: View {
    let environment: AppEnvironment
    let healthOverviewViewModel: HealthOverviewViewModel
    let insightsViewModel: HealthInsightsViewModel
    let goalsViewModel: WorkoutGoalsViewModel
    let progressViewModel: WorkoutAnalysisViewModel

    /// 底部标签。页面之间的快捷入口（如“看看本周训练”“设定目标”）通过切换它跳转。
    enum Tab: Hashable {
        case today
        case workout
        case goals
        case progress
    }

    @State private var selection: Tab = .today
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selection) {
            HealthOverviewView(
                viewModel: healthOverviewViewModel,
                service: environment.healthDataService,
                onOpenTraining: { selection = .workout }
            )
            .tabItem { Label("今日", systemImage: "sun.max") }
            .tag(Tab.today)

            WorkoutHomeView(
                monitor: environment.liveWorkoutMonitor,
                simulatedWorkout: environment.simulatedWorkout,
                historyService: environment.workoutHistoryService,
                goalsViewModel: goalsViewModel,
                onOpenGoals: { selection = .goals },
                onSimulatedWorkoutCompleted: environment.recordSimulatedWorkout
            )
            .tabItem { Label("运动", systemImage: "figure.run") }
            .tag(Tab.workout)

            WorkoutGoalsView(viewModel: goalsViewModel)
                .tabItem { Label("目标", systemImage: "target") }
                .tag(Tab.goals)

            InsightsView(
                viewModel: insightsViewModel,
                service: environment.healthDataService,
                progressViewModel: progressViewModel,
                workoutService: environment.workoutHistoryService,
                goalsViewModel: goalsViewModel,
                onOpenGoals: { selection = .goals }
            )
            .tabItem { Label("进步", systemImage: "chart.line.uptrend.xyaxis") }
            .tag(Tab.progress)
        }
        .onChange(of: scenePhase) { _, phase in
            // 后台期间计时器暂停；回到前台立即检查一次连接是否已超时。
            if phase == .active {
                environment.liveWorkoutMonitor.evaluateConnection()
            }
        }
    }
}
