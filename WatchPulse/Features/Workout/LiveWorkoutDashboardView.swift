import Charts
import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// iPhone 实时运动仪表盘：数据来自 Apple Watch 镜像会话。
struct LiveWorkoutDashboardView: View {
    let monitor: LiveWorkoutMonitor
    @State private var isConfirmingEnd = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if monitor.dataOrigin.isSimulated {
                    DemoModeBanner()
                }
                header
                ConnectionBadge(connection: monitor.connection)
                    .accessibilityIdentifier("live.connection")

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(MetricFormatting.clock(seconds: monitor.elapsedTime(at: context.date)))
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(monitor.phase == .running ? .primary : .secondary)
                        .accessibilityIdentifier("live.elapsed")
                }

                metricGrid
                heartRateChart
                controls
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("实时运动")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // 定期检测“长时间没有数据”。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                monitor.evaluateConnection()
            }
        }
        .confirmationDialog("结束 Apple Watch 上的运动？", isPresented: $isConfirmingEnd, titleVisibility: .visible) {
            Button("结束并保存", role: .destructive) {
                monitor.send(.end)
            }
        }
    }

    private var header: some View {
        HStack {
            Label(
                monitor.configuration?.activity.title ?? "运动",
                systemImage: monitor.configuration?.activity.systemImage ?? "figure.run"
            )
            .font(.title3.weight(.semibold))
            Spacer()
            Text(monitor.phase.title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(phaseColor.opacity(0.15), in: Capsule())
                .foregroundStyle(phaseColor)
                .accessibilityIdentifier("live.phase")
        }
    }

    private var phaseColor: Color {
        switch monitor.phase {
        case .running: return .green
        case .paused: return .orange
        case .ended, .stopped: return .secondary
        case .notStarted, .prepared: return .blue
        }
    }

    private var metricGrid: some View {
        let metrics = monitor.latestMetrics
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            tile("心率", value: metrics?.heartRateBPM.map { "\(Int($0.rounded()))" }, unit: "次/分", image: "heart.fill", tint: .red)
                .accessibilityIdentifier("live.heartRate")
            tile("活动能量", value: metrics?.activeEnergyKilocalories.map { "\(Int($0.rounded()))" }, unit: "千卡", image: "flame.fill", tint: .green)
            if monitor.configuration?.activity.tracksDistance ?? true {
                tile("距离", value: metrics?.distanceMeters.map(MetricFormatting.distance(meters:)), unit: "", image: "location.fill", tint: .cyan)
            }
            if let maximum = monitor.heartRateHistory.map(\.beatsPerMinute).max() {
                tile("最高心率", value: "\(Int(maximum.rounded()))", unit: "次/分", image: "arrow.up.heart.fill", tint: .pink)
            }
        }
    }

    private func tile(_ title: String, value: String?, unit: String, image: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: image)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "--")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var heartRateChart: some View {
        let points = HeartRateSeries.downsample(monitor.heartRateHistory, maxPoints: 240)
        if points.count >= 2 {
            VStack(alignment: .leading, spacing: 8) {
                Text("心率曲线").font(.headline)
                Chart(points) { point in
                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("心率", point.beatsPerMinute)
                    )
                    .foregroundStyle(.red)
                    .interpolationMethod(.catmullRom)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 180)
                .accessibilityIdentifier("live.heartRateChart")
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if let error = monitor.commandError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("live.commandError")
            }
            if monitor.phase.isActive {
                HStack(spacing: 12) {
                    if monitor.phase == .paused {
                        Button {
                            monitor.send(.resume)
                        } label: {
                            Label("继续", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .accessibilityIdentifier("live.resume")
                    } else {
                        Button {
                            monitor.send(.pause)
                        } label: {
                            Label("暂停", systemImage: "pause.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .accessibilityIdentifier("live.pause")
                    }
                    Button(role: .destructive) {
                        isConfirmingEnd = true
                    } label: {
                        Label("结束", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("live.end")
                }
                .disabled(monitor.pendingCommand != nil)
                if let pending = monitor.pendingCommand {
                    Text("正在请求 Apple Watch \(pending.title)…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if monitor.phase == .ended {
                Text("运动已在 Apple Watch 上结束并保存。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("完成") {
                    monitor.reset()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("live.done")
            }
        }
    }
}

private struct ConnectionBadge: View {
    let connection: LiveWorkoutMonitor.ConnectionState

    var body: some View {
        Label(connection.title, systemImage: icon)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var icon: String {
        switch connection {
        case .connected: return "applewatch.radiowaves.left.and.right"
        case .stale: return "wifi.exclamationmark"
        case .waiting: return "applewatch"
        case .disconnected: return "applewatch.slash"
        }
    }

    private var color: Color {
        switch connection {
        case .connected: return .green
        case .stale: return .orange
        case .waiting: return .secondary
        case .disconnected: return .red
        }
    }
}
