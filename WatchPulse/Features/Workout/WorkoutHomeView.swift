import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// 运动页：实时运动入口（来自 Apple Watch 镜像）+ 演示模式控制。
struct WorkoutHomeView: View {
    let monitor: LiveWorkoutMonitor
    let simulatedWorkout: SimulatedMirroredWorkout?

    var body: some View {
        NavigationStack {
            List {
                if monitor.dataOrigin.isSimulated {
                    DemoModeBanner()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("实时运动") {
                    if monitor.hasWorkout {
                        NavigationLink {
                            LiveWorkoutDashboardView(monitor: monitor)
                        } label: {
                            LiveWorkoutRow(monitor: monitor)
                        }
                        .accessibilityIdentifier("workout.liveRow")
                    } else {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("等待 Apple Watch 开始运动")
                                Text("在 Apple Watch 上打开 WatchPulse 并开始运动，iPhone 会自动显示实时心率、能量与距离。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "applewatch.radiowaves.left.and.right")
                        }
                        .accessibilityIdentifier("workout.waiting")
                    }
                }

                if let simulatedWorkout {
                    SimulationControls(simulation: simulatedWorkout)
                }
            }
            .navigationTitle("运动")
        }
    }
}

private struct LiveWorkoutRow: View {
    let monitor: LiveWorkoutMonitor

    var body: some View {
        HStack {
            Image(systemName: monitor.configuration?.activity.systemImage ?? "figure.run")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.configuration?.activity.title ?? "运动")
                    .font(.headline)
                Text("\(monitor.phase.title) · \(monitor.connection.title)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(MetricFormatting.clock(seconds: monitor.elapsedTime(at: context.date)))
                    .font(.headline)
                    .monospacedDigit()
            }
        }
    }
}

/// 演示模式：在 iPhone 上模拟一只 Apple Watch 发起运动，用于验证实时仪表盘、命令与断线恢复流程。
private struct SimulationControls: View {
    let simulation: SimulatedMirroredWorkout

    var body: some View {
        Section {
            if simulation.watch.phase.isActive {
                if simulation.isOutageActive {
                    Button("恢复连接") { simulation.endOutage() }
                        .accessibilityIdentifier("demo.endOutage")
                } else {
                    Button("模拟断线") { simulation.beginOutage() }
                        .accessibilityIdentifier("demo.beginOutage")
                }
                LabeledContent("模拟 Watch 状态", value: simulation.watch.phase.title)
                LabeledContent(
                    "Watch 镜像连接",
                    value: simulation.watch.isMirroringConnected ? "已连接" : (simulation.watch.isReconnecting ? "重连中" : "未连接")
                )
            } else {
                ForEach([WorkoutActivityKind.running, .cycling, .highIntensityIntervalTraining], id: \.self) { activity in
                    Button {
                        Task {
                            await simulation.start(WorkoutConfigurationRequest(activity: activity, location: .outdoor))
                            simulation.startLoop()
                        }
                    } label: {
                        Label("开始模拟\(activity.title)", systemImage: activity.systemImage)
                    }
                    .accessibilityIdentifier("demo.start.\(activity.rawValue)")
                }
            }
        } header: {
            Text("演示：模拟 Apple Watch")
        } footer: {
            Text("仅演示模式可用。数据由模拟器生成，不来自真实设备，也不会写入“健康”。")
        }
    }
}

#Preview("演示模式") {
    let monitor = LiveWorkoutMonitor(dataOrigin: .simulated)
    return WorkoutHomeView(monitor: monitor, simulatedWorkout: SimulatedMirroredWorkout(monitor: monitor))
}

#Preview("等待") {
    WorkoutHomeView(monitor: LiveWorkoutMonitor(dataOrigin: .healthKit), simulatedWorkout: nil)
}
