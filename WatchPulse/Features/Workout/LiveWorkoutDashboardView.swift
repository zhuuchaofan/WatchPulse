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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.cardSpacing) {
                if monitor.dataOrigin.isSimulated {
                    DemoModeBanner()
                }
                header

                if isCycling {
                    CyclingDashboardPanel(monitor: monitor, isLargeMode: isCyclingLargeMode)
                    if !isCyclingLargeMode, monitor.heartRateHistory.count >= 2 {
                        heartRateChart
                            .cardStyle()
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(MetricFormatting.clock(seconds: monitor.elapsedTime(at: context.date)))
                            .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(monitor.phase == .running ? Theme.text : Theme.secondaryText)
                            .accessibilityLabel("已用时间 \(MetricFormatting.clock(seconds: monitor.elapsedTime(at: context.date)))")
                            .accessibilityIdentifier("live.elapsed")
                    }
                    heartRateCard
                    metricGrid
                }
                controls
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.vertical, 8)
        }
        .background(Theme.background.ignoresSafeArea())
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

    /// 运动类型 · 状态，以及与 Apple Watch 的连接。
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) { headerContent }
            VStack(alignment: .leading, spacing: 8) { headerContent }
        }
    }

    @ViewBuilder
    private var headerContent: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: monitor.configuration?.activity.systemImage ?? "figure.run")
                .foregroundStyle(Theme.sage)
                .accessibilityHidden(true)
            Text(monitor.configuration?.activity.title ?? "运动")
                .font(.headline)
                .foregroundStyle(Theme.text)
            Text(monitor.phase.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(phaseColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(phaseBackground, in: Capsule())
                .accessibilityIdentifier("live.phase")
        }
        Spacer(minLength: 8)
        ConnectionBadge(connection: monitor.connection)
            .accessibilityIdentifier("live.connection")
    }

    private var phaseColor: Color {
        switch monitor.phase {
        case .running: return Theme.sageText
        case .paused: return Theme.apricotText
        case .ended, .stopped, .notStarted, .prepared: return Theme.secondaryText
        }
    }

    private var phaseBackground: Color {
        switch monitor.phase {
        case .running: return Theme.mint
        default: return Theme.line
        }
    }

    /// 实时心率：大号数字 + 最近 5 分钟曲线。
    private var heartRateCard: some View {
        let heartRate = monitor.latestMetrics?.heartRateBPM.map { "\(Int($0.rounded()))" }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(Theme.sage)
                    .accessibilityHidden(true)
                Text("心率").font(.subheadline).foregroundStyle(Theme.secondaryText)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(heartRate ?? "--")
                    .font(.system(size: 64, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                Text("次/分").font(.body).foregroundStyle(Theme.secondaryText)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("live.heartRate")
            heartRateChart
        }
        .cardStyle()
    }

    private var metricGrid: some View {
        let metrics = monitor.latestMetrics
        let columns = dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            if monitor.configuration?.activity.tracksDistance ?? true {
                tile("距离", value: metrics?.distanceMeters.map(MetricFormatting.distance(meters:)), unit: "")
            }
            tile("活动能量", value: metrics?.activeEnergyKilocalories.map { "\(Int($0.rounded()))" }, unit: "千卡")
            if let maximum = monitor.heartRateHistory.map(\.beatsPerMinute).max() {
                tile("最高心率", value: "\(Int(maximum.rounded()))", unit: "次/分")
            }
        }
    }

    private func tile(_ title: String, value: String?, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote).foregroundStyle(Theme.secondaryText)
            MetricNumber(value: value ?? "--", unit: unit.isEmpty ? nil : unit, style: .title2)
        }
        .cardStyle(padding: 16)
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
                Chart(visible) { point in
                    LineMark(
                        x: .value("时间", point.date),
                        y: .value("心率", point.beatsPerMinute)
                    )
                    .foregroundStyle(Theme.sage)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
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
                .frame(height: 120)
                .accessibilityLabel("最近 5 分钟心率，在 \(Int(values.min() ?? 0)) 到 \(Int(values.max() ?? 0)) 次/分之间")
                .accessibilityIdentifier("live.heartRateChart")
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        VStack(spacing: 10) {
            if let error = monitor.commandError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.notice)
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
                            Label("继续", systemImage: "play.fill")
                        }
                        .buttonStyle(LiveControlButtonStyle(kind: .outline))
                        .accessibilityIdentifier("live.resume")
                    } else {
                        Button {
                            monitor.send(.pause)
                        } label: {
                            Label("暂停", systemImage: "pause.fill")
                        }
                        .buttonStyle(LiveControlButtonStyle(kind: .outline))
                        .accessibilityIdentifier("live.pause")
                    }
                    Button {
                        isConfirmingEnd = true
                    } label: {
                        Label("结束", systemImage: "stop.fill")
                    }
                    .buttonStyle(LiveControlButtonStyle(kind: .end))
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
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Text("“结束”需要在确认框里再点一次，避免误触")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                }
            } else if monitor.phase == .ended {
                SaveStatusLabel(status: monitor.saveStatus, isSimulated: monitor.dataOrigin.isSimulated)
                    .accessibilityIdentifier("live.saveStatus")
                Button("完成") {
                    monitor.reset()
                }
                .buttonStyle(.themePrimary)
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
            .foregroundStyle(isSimulated ? Theme.notice : Theme.sageText)
        case .failed:
            // 原因来自系统错误，只用于调试，不显示给用户。
            Label(WorkoutSessionError.saveFailed(reason: "").localizedDescription, systemImage: "xmark.octagon.fill")
                .foregroundStyle(Theme.apricotText)
        case .saving, .pending:
            Label("运动已结束，尚未收到保存结果。请在 Apple Watch 或「健康」App 中确认。", systemImage: "questionmark.circle")
                .foregroundStyle(Theme.notice)
        }
    }
}

private struct ConnectionBadge: View {
    let connection: LiveWorkoutMonitor.ConnectionState

    var body: some View {
        Label(connection.title, systemImage: icon)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(color)
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
        case .connected: return Theme.sageText
        case .stale: return Theme.apricotText
        case .waiting: return Theme.secondaryText
        case .disconnected: return Theme.apricotText
        }
    }
}

/// 运动中的大按钮：至少 60pt 高，便于运动时点按。
private struct LiveControlButtonStyle: ButtonStyle {
    enum Kind { case outline, end }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 60)
            .foregroundStyle(kind == .end ? Theme.endButtonText : Theme.sageText)
            .background {
                switch kind {
                case .end: Capsule().fill(Theme.endButton)
                case .outline: Capsule().strokeBorder(Theme.sageText, lineWidth: 1.5)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(Capsule())
    }
}
