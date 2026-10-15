import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// Watch 首页：选择运动类型开始；运动中显示实时数据（骑行为专用码表页）；结束后显示摘要。
struct WatchHomeView: View {
    let environment: WatchAppEnvironment

    private var controller: WorkoutSessionController { environment.controller }

    var body: some View {
        NavigationStack {
            Group {
                if controller.phase == .ended {
                    WatchSummaryView(controller: controller)
                } else if controller.phase.isActive {
                    if controller.configuration?.activity == .cycling {
                        WatchCyclingLiveView(environment: environment)
                    } else {
                        WatchLiveWorkoutView(controller: controller)
                    }
                } else {
                    WatchStartView(environment: environment)
                }
            }
        }
    }
}

private struct WatchStartView: View {
    let environment: WatchAppEnvironment
    @State private var isIndoor = false

    private var controller: WorkoutSessionController { environment.controller }

    var body: some View {
        List {
            if environment.isDemoMode {
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
                    environment.applyZoneSettings()
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
            NavigationLink {
                WatchZoneSettingsView(environment: environment)
            } label: {
                Label("心率区间与提醒", systemImage: "heart.circle")
            }
        }
        .navigationTitle("WatchPulse")
    }
}

/// 暂停 / 继续 / 结束按钮（各运动页共用）。
private struct WatchWorkoutControls: View {
    let controller: WorkoutSessionController
    @State private var isConfirmingEnd = false

    var body: some View {
        HStack {
            if controller.phase == .paused {
                Button {
                    controller.resume()
                } label: {
                    Image(systemName: "play.fill")
                }
                .tint(.green)
                .accessibilityLabel("继续")
            } else {
                Button {
                    controller.pause()
                } label: {
                    Image(systemName: "pause.fill")
                }
                .tint(.yellow)
                .disabled(controller.phase != .running)
                .accessibilityLabel("暂停")
            }
            Button(role: .destructive) {
                isConfirmingEnd = true
            } label: {
                Image(systemName: "xmark")
            }
            .disabled(controller.isBusy)
            .accessibilityLabel("结束")
        }
        .padding(.top, 4)
        .confirmationDialog("结束运动？", isPresented: $isConfirmingEnd) {
            Button("结束并保存", role: .destructive) {
                Task { await controller.end() }
            }
        }
    }
}

struct WatchLiveWorkoutView: View {
    let controller: WorkoutSessionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(controller.configuration?.activity.title ?? "运动", systemImage: controller.configuration?.activity.systemImage ?? "figure.run")
                        .font(.footnote)
                    Spacer()
                    MirroringIcon(isConnected: controller.isMirroringConnected)
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

                WatchWorkoutControls(controller: controller)
            }
            .padding(.horizontal, 4)
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

private struct MirroringIcon: View {
    let isConnected: Bool

    var body: some View {
        Image(systemName: isConnected ? "iphone" : "iphone.slash")
            .foregroundStyle(isConnected ? .green : .secondary)
            .accessibilityLabel(isConnected ? "已连接 iPhone" : "未连接 iPhone")
    }
}

/// 骑行码表页：心率 + 区间、GPS 速度（带来源 / 有效性）、距离、时长、运动均速。
private struct WatchCyclingLiveView: View {
    let environment: WatchAppEnvironment

    private var controller: WorkoutSessionController { environment.controller }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let display = CyclingDisplayModel(
                configuration: controller.configuration,
                metrics: controller.latestMetrics,
                phase: controller.phase,
                zones: environment.zoneStore.zones,
                targetZone: environment.zoneStore.activeTargetZone,
                isLinkHealthy: true,
                now: context.date
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(display.zone.map(\.title) ?? "骑行")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(zoneColor(display.zone))
                        if let target = display.targetZone {
                            Text("目标 \(target.title)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        MirroringIcon(isConnected: controller.isMirroringConnected)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "heart.fill").foregroundStyle(.red)
                        Text(display.heartRateText)
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                        Text("次/分").font(.footnote).foregroundStyle(.secondary)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(display.speedText)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(display.isSpeedLive ? .primary : .secondary)
                        Text("km/h").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(display.speedStatusText)
                        .font(.footnote)
                        .foregroundStyle(display.isSpeedLive ? Color.secondary : Color.orange)

                    Text("\(display.distanceText) · \(MetricFormatting.clock(seconds: controller.elapsedTime(at: context.date)))")
                        .font(.footnote)
                        .monospacedDigit()
                    Text("运动均速 \(display.averageSpeedText) km/h")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let alert = environment.zoneAlertMonitor.lastAlert, context.date.timeIntervalSince(alert.date) < 30 {
                        Text(alert.kind == .aboveZone ? "高于目标区间" : "低于目标区间")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    if controller.phase == .paused {
                        Text("已暂停").font(.footnote).foregroundStyle(.orange)
                    }

                    WatchWorkoutControls(controller: controller)
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func zoneColor(_ zone: TrainingZone?) -> Color {
        switch zone {
        case .z1: return .blue
        case .z2: return .green
        case .z3: return .yellow
        case .z4: return .orange
        case .z5: return .red
        case nil: return .secondary
        }
    }
}

/// 心率区间与震动提醒设置。只能由用户输入最大心率或区间下限，不使用年龄公式。
private struct WatchZoneSettingsView: View {
    let environment: WatchAppEnvironment

    @State private var maximum: Int
    @State private var isCustom: Bool
    @State private var bounds: [Int]
    @State private var alert: ZoneAlertSettings
    @State private var message: String?

    private var store: HeartRateZoneSettingsStore { environment.zoneStore }

    init(environment: WatchAppEnvironment) {
        self.environment = environment
        let zones = environment.zoneStore.zones
        _maximum = State(initialValue: zones?.maximumHeartRate ?? 180)
        _isCustom = State(initialValue: zones?.method == .custom)
        _bounds = State(initialValue: zones?.lowerBounds ?? (try? HeartRateZoneSettings.percentOfMaximum(180))?.lowerBounds ?? [90, 108, 126, 144, 162])
        _alert = State(initialValue: environment.zoneStore.alert)
    }

    var body: some View {
        List {
            Section {
                Stepper(value: $maximum, in: HeartRateZoneSettings.maximumRange) {
                    Text("\(maximum) 次/分").monospacedDigit()
                }
            } header: {
                Text("最大心率")
            } footer: {
                Text("请输入你实测或已知的最大心率。WatchPulse 不用年龄公式推算。")
            }

            Section("区间") {
                Toggle("自定义下限", isOn: $isCustom)
                if isCustom {
                    ForEach(TrainingZone.allCases) { zone in
                        Stepper(value: $bounds[zone.rawValue - 1], in: HeartRateZoneSettings.minimumBoundary...(maximum - 1)) {
                            Text("\(zone.title) ≥ \(bounds[zone.rawValue - 1])").monospacedDigit()
                        }
                    }
                } else if let preview = try? HeartRateZoneSettings.percentOfMaximum(maximum) {
                    ForEach(TrainingZone.allCases) { zone in
                        Text("\(zone.title) \(preview.range(of: zone).lowerBound)–\(preview.range(of: zone).upperBound)")
                            .monospacedDigit()
                    }
                }
                Button("保存区间") { saveZones() }
                if store.zones != nil {
                    Button("清除区间", role: .destructive) {
                        store.resetZones()
                        alert = store.alert
                        environment.applyZoneSettings()
                        message = "已清除"
                    }
                }
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("偏离目标区间时震动", isOn: $alert.isEnabled)
                    .disabled(store.zones == nil)
                Picker("目标区间", selection: $alert.targetZone) {
                    ForEach(TrainingZone.allCases) { zone in
                        Text("\(zone.title) \(zone.name)").tag(zone)
                    }
                }
            } header: {
                Text("震动提醒")
            } footer: {
                Text(store.zones == nil
                     ? "请先保存心率区间。"
                     : "持续偏离约 10 秒才震动；同一次偏离只提醒一次，两次至少间隔 1 分钟。仅作训练参考，不是医学建议。")
            }
        }
        .navigationTitle("心率区间")
        .onChange(of: alert) { _, newValue in
            store.save(alert: newValue)
            alert = store.alert
            environment.applyZoneSettings()
        }
    }

    private func saveZones() {
        do {
            let zones = isCustom
                ? try HeartRateZoneSettings(method: .custom, maximumHeartRate: maximum, lowerBounds: bounds)
                : try HeartRateZoneSettings.percentOfMaximum(maximum)
            store.save(zones: zones)
            bounds = zones.lowerBounds
            environment.applyZoneSettings()
            message = "已保存"
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "区间无效"
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
                    if record.activity == .cycling, let speed = record.averageSpeedMetersPerSecond {
                        Text("运动均速 \(MetricFormatting.speedKilometersPerHour(speed)) km/h")
                    }
                    if let heartRate = record.averageHeartRate {
                        Text("平均心率 \(Int(heartRate.rounded())) 次/分")
                    }
                }
                if controller.dataOrigin.isSimulated {
                    Text("模拟数据，未写入“健康”").font(.footnote).foregroundStyle(.orange)
                } else if controller.saveStatus.isSaved {
                    Text("已保存到“健康”").font(.footnote).foregroundStyle(.secondary)
                } else if case .failed = controller.saveStatus {
                    Text("未能保存到“健康”").font(.footnote).foregroundStyle(.red)
                }
                if controller.finalStateDelivered == false {
                    Text("未能把结果同步到 iPhone，请在 iPhone 的「健康」App 中确认").font(.footnote).foregroundStyle(.orange)
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
