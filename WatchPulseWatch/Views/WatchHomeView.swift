import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// Watch 首页：选择运动类型开始；运动中显示实时数据；结束后显示摘要。
struct WatchHomeView: View {
    let controller: WorkoutSessionController
    let isDemoMode: Bool

    var body: some View {
        NavigationStack {
            Group {
                if controller.phase == .ended {
                    WatchSummaryView(controller: controller)
                } else if controller.phase.isActive {
                    WatchLiveWorkoutView(controller: controller)
                } else {
                    WatchStartView(controller: controller, isDemoMode: isDemoMode)
                }
            }
        }
    }
}

private struct WatchStartView: View {
    let controller: WorkoutSessionController
    let isDemoMode: Bool
    @State private var isIndoor = false

    var body: some View {
        List {
            if isDemoMode {
                Text("演示模式 · 模拟数据")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if let error = controller.lastError {
                Text(error.localizedDescription)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Toggle("室内", isOn: $isIndoor)
            ForEach(WorkoutActivityKind.allCases, id: \.self) { activity in
                Button {
                    Task {
                        await controller.start(WorkoutConfigurationRequest(
                            activity: activity,
                            location: isIndoor ? .indoor : .outdoor
                        ))
                    }
                } label: {
                    Label(activity.title, systemImage: activity.systemImage)
                }
                .disabled(controller.isBusy)
            }
        }
        .navigationTitle("WatchPulse")
    }
}

struct WatchLiveWorkoutView: View {
    let controller: WorkoutSessionController
    @State private var isConfirmingEnd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(controller.configuration?.activity.title ?? "运动", systemImage: controller.configuration?.activity.systemImage ?? "figure.run")
                        .font(.footnote)
                    Spacer()
                    Image(systemName: controller.isMirroringConnected ? "iphone" : "iphone.slash")
                        .foregroundStyle(controller.isMirroringConnected ? .green : .secondary)
                        .accessibilityLabel(controller.isMirroringConnected ? "已连接 iPhone" : "未连接 iPhone")
                }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(MetricFormatting.clock(seconds: controller.elapsedTime(at: context.date)))
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.yellow)
                }

                metric(
                    controller.latestMetrics?.heartRateBPM.map { "\(Int($0.rounded()))" } ?? "--",
                    unit: "次/分",
                    systemImage: "heart.fill",
                    tint: .red
                )
                metric(
                    controller.latestMetrics?.activeEnergyKilocalories.map { "\(Int($0.rounded()))" } ?? "--",
                    unit: "千卡",
                    systemImage: "flame.fill",
                    tint: .green
                )
                if controller.configuration?.activity.tracksDistance == true {
                    metric(
                        controller.latestMetrics?.distanceMeters.map(MetricFormatting.distance(meters:)) ?? "--",
                        unit: "",
                        systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                        tint: .cyan
                    )
                }

                if controller.phase == .paused {
                    Text("已暂停").font(.footnote).foregroundStyle(.orange)
                }

                HStack {
                    if controller.phase == .paused {
                        Button {
                            controller.resume()
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .tint(.green)
                    } else {
                        Button {
                            controller.pause()
                        } label: {
                            Image(systemName: "pause.fill")
                        }
                        .tint(.yellow)
                        .disabled(controller.phase != .running)
                    }
                    Button(role: .destructive) {
                        isConfirmingEnd = true
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .disabled(controller.isBusy)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 4)
        }
        .confirmationDialog("结束运动？", isPresented: $isConfirmingEnd) {
            Button("结束并保存", role: .destructive) {
                Task { await controller.end() }
            }
        }
    }

    private func metric(_ value: String, unit: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            if !unit.isEmpty {
                Text(unit).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct WatchSummaryView: View {
    let controller: WorkoutSessionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("运动已结束").font(.headline)
                if let record = controller.completedWorkout {
                    Label(record.activity.title, systemImage: record.activity.systemImage)
                    Text("时长 \(MetricFormatting.clock(seconds: record.duration))")
                    if let energy = record.activeEnergyKilocalories {
                        Text("活动能量 \(Int(energy.rounded())) 千卡")
                    }
                    if let distance = record.distanceMeters {
                        Text("距离 \(MetricFormatting.distance(meters: distance))")
                    }
                    if let heartRate = record.averageHeartRate {
                        Text("平均心率 \(Int(heartRate.rounded())) 次/分")
                    }
                    if controller.dataOrigin.isSimulated {
                        Text("模拟数据，未写入“健康”").font(.footnote).foregroundStyle(.orange)
                    } else {
                        Text("已保存到“健康”").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let error = controller.lastError {
                    Text(error.localizedDescription).font(.footnote).foregroundStyle(.red)
                }
                Button("完成") {
                    controller.dismissSummary()
                }
                .padding(.top, 4)
            }
        }
    }
}

#Preview("开始") {
    WatchHomeView(
        controller: WorkoutSessionController(driver: SimulatedWorkoutSessionDriver(), sender: nil),
        isDemoMode: true
    )
}
