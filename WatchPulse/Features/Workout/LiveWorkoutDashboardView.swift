import Charts
import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// iPhone 实时运动仪表盘：数据来自 Apple Watch 镜像会话。
struct LiveWorkoutDashboardView: View {
    let monitor: LiveWorkoutMonitor
    @State private var isConfirmingEnd = false
    /// 骑行：大字码表模式（默认开启）。
    @AppStorage("WatchPulse.cyclingLargeMode") private var isCyclingLargeMode = true

    private var isCycling: Bool { monitor.configuration?.activity == .cycling }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if monitor.dataOrigin.isSimulated {
                    DemoModeBanner()
                }
                header
                ConnectionBadge(connection: monitor.connection)
                    .accessibilityIdentifier("live.connection")

                if isCycling {
                    CyclingDashboardPanel(monitor: monitor, isLargeMode: isCyclingLargeMode)
                    if !isCyclingLargeMode {
                        heartRateChart
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(MetricFormatting.clock(seconds: monitor.elapsedTime(at: context.date)))
                            .font(.system(size: 56, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(monitor.phase == .running ? .primary : .secondary)
                            .accessibilityIdentifier("live.elapsed")
                    }

                    metricGrid
                    heartRateChart
                }
                controls
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(isCycling ? "骑行" : "实时运动")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isCycling {
                Button {
                    isCyclingLargeMode.toggle()
                } label: {
                    Label(isCyclingLargeMode ? "标准视图" : "大字模式", systemImage: isCyclingLargeMode ? "chart.xyaxis.line" : "textformat.size.larger")
                }
                .accessibilityIdentifier("cycling.toggleLargeMode")
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
        .accessibilityElement(children: .combine)
    }

    /// 实时曲线只显示最近这么久（秒），更早的数据留给运动结束后的详情页。
    private static let chartWindow: TimeInterval = 300

    @ViewBuilder
    private var heartRateChart: some View {
        let history = HeartRateSeries.downsample(monitor.heartRateHistory, maxPoints: 240)
        if let first = history.first?.date, let last = history.last?.date, history.count >= 2 {
            // 起点从运动开始的第一个心率样本算起；满窗口后只保留最近 `chartWindow` 秒。
            let lower = max(first, last.addingTimeInterval(-Self.chartWindow))
            let upper = max(last, lower.addingTimeInterval(30))
            let visible = history.filter { $0.date >= lower.addingTimeInterval(-30) }
            let values = visible.map(\.beatsPerMinute)
            let yLower = ((values.min() ?? 60) - 5).rounded(.down)
            let yUpper = ((values.max() ?? 120) + 5).rounded(.up)
            // 刚开始运动时用 30 秒刻度（带秒）；之后每分钟一个刻度，5 分钟窗口约 5~6 个标签，不拥挤。
            let showsSeconds = upper.timeIntervalSince(lower) <= 90
            VStack(alignment: .leading, spacing: 8) {
                Text("心率曲线").font(.headline)
                Chart(visible) { point in
                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("心率", point.beatsPerMinute)
                    )
                    .foregroundStyle(.red)
                    .interpolationMethod(.monotone)
                }
                .chartXScale(domain: lower...upper)
                .chartYScale(domain: yLower...yUpper)
                .chartXAxis {
                    AxisMarks(preset: .aligned, values: showsSeconds ? .stride(by: .second, count: 30) : .stride(by: .minute)) { _ in
                        AxisGridLine()
                        AxisValueLabel(
                            format: showsSeconds
                                ? .dateTime.hour().minute().second()
                                : .dateTime.hour().minute(),
                            anchor: .top
                        )
                    }
                }
                .chartPlotStyle { $0.clipped() }
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
            if monitor.phase == .stopped {
                Label("Apple Watch 正在结束并保存运动…", systemImage: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("live.stopping")
            } else if monitor.canSendCommands {
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
                if monitor.saveStatus == .saving {
                    Label("Apple Watch 正在保存运动…", systemImage: "arrow.down.doc")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let pending = monitor.pendingCommand {
                    Text("正在请求 Apple Watch \(pending.title)…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else if monitor.phase == .ended {
                SaveStatusLabel(status: monitor.saveStatus, isSimulated: monitor.dataOrigin.isSimulated)
                    .accessibilityIdentifier("live.saveStatus")
                Button("完成") {
                    monitor.reset()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("live.done")
            }
        }
    }
}

/// 运动结束后的保存结果。只有收到 Watch 的“已保存”才显示保存成功。
private struct SaveStatusLabel: View {
    let status: WorkoutSaveStatus
    let isSimulated: Bool

    var body: some View {
        switch status {
        case .saved:
            Label(
                isSimulated ? "模拟运动已结束（模拟数据，未写入“健康”）" : "运动已结束，Apple Watch 已保存到“健康”",
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(isSimulated ? .orange : .green)
        case .failed:
            // 原因来自系统错误，只用于调试，不显示给用户。
            Label(WorkoutSessionError.saveFailed(reason: "").localizedDescription, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .saving, .pending:
            Label("运动已结束，尚未收到保存结果。请在 Apple Watch 或「健康」App 中确认。", systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
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
