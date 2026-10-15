import SwiftUI
import WatchPulseShared

struct WatchHomeView: View {
    let workoutManager: WatchWorkoutManager

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "heart.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.red)

                    Text("WatchPulse")
                        .font(.headline)

                    Text(workoutManager.isHealthDataAvailable ? "HealthKit 可用" : "HealthKit 不可用")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        // 下一阶段：workoutManager.startWorkout(...)
                    } label: {
                        Label("开始运动", systemImage: "figure.run")
                    }
                    .disabled(true)

                    Text("实时运动与 iPhone 镜像将在下一阶段接入。")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
            }
            .navigationTitle("WatchPulse")
        }
    }
}

#Preview {
    WatchHomeView(workoutManager: WatchWorkoutManager())
}
