import Charts
import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// 近 30 天骑行统计（来自运动记录）。
private struct CyclingStatisticsRow: View {
    let statistics: CyclingStatistics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("\(statistics.rideCount) 次骑行", systemImage: "figure.outdoor.cycle")
                    .font(.headline)
                Spacer()
                Text(MetricFormatting.distance(meters: statistics.totalDistanceMeters))
                    .font(.headline)
                    .monospacedDigit()
            }
            HStack(spacing: 16) {
                LabeledContent("运动时长", value: MetricFormatting.clock(seconds: statistics.totalDuration))
                LabeledContent("运动均速", value: statistics.averageSpeedMetersPerSecond.map { "\(MetricFormatting.speedKilometersPerHour($0)) km/h" } ?? "--")
            }
            .font(.footnote)
            if let longest = statistics.longestRideMeters {
                Text("单次最长 \(MetricFormatting.distance(meters: longest))。均速 = 有距离记录的骑行总距离 ÷ 运动时长（不含暂停）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workout.cyclingStats")
    }
}

/// 运动页中的“运动记录”分组。
struct WorkoutHistorySection: View {
    let viewModel: WorkoutHistoryViewModel

    var body: some View {
        switch viewModel.state {
        case .loaded(let workouts):
            if let cycling = CyclingStatistics.recent(workouts, days: 30, endingAt: .now) {
                Section("近 30 天骑行") {
                    CyclingStatisticsRow(statistics: cycling)
                }
            }
            ForEach(WorkoutHistoryViewModel.groupedByMonth(workouts), id: \.month) { group in
                Section(group.month.formatted(.dateTime.year().month(.wide))) {
                    ForEach(group.workouts) { workout in
                        NavigationLink(value: workout) {
                            WorkoutRow(workout: workout)
                        }
                        .accessibilityIdentifier("workout.history.row")
                    }
                }
            }
        default:
            Section("运动记录") {
                LoadStateView(
                    state: viewModel.state,
                    noDataTitle: "暂无运动记录",
                    noDataMessage: "在 Apple Watch 上用 WatchPulse 完成运动后会出现在这里。若“健康”中已有运动，请检查读取运动的权限。",
                    retry: { await viewModel.load() }
                ) { _ in EmptyView() }
            }
        }
    }
}

private struct WorkoutRow: View {
    let workout: WorkoutRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: workout.activity.systemImage)
                .font(.title2)
                .foregroundStyle(.green)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.activity.title)
                    .font(.headline)
                Text(workout.startDate.formatted(.dateTime.month().day().weekday().hour().minute()))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(MetricFormatting.clock(seconds: workout.duration))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                if let distance = workout.distanceMeters {
                    Text(MetricFormatting.distance(meters: distance))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let energy = workout.activeEnergyKilocalories {
                    Text("\(Int(energy.rounded())) 千卡")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct WorkoutDetailScreen: View {
    @State private var viewModel: WorkoutDetailViewModel

    init(workout: WorkoutRecord, service: any WorkoutHistoryService) {
        _viewModel = State(initialValue: WorkoutDetailViewModel(workout: workout, service: service))
    }

    var body: some View {
        WorkoutDetailView(viewModel: viewModel)
    }
}

/// 运动详情：汇总数据 + 心率曲线 + 心率区间。
struct WorkoutDetailView: View {
    let viewModel: WorkoutDetailViewModel

    private var workout: WorkoutRecord { viewModel.workout }

    var body: some View {
        List {
            if viewModel.dataOrigin.isSimulated {
                DemoModeBanner()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("类型", value: "\(workout.activity.title) · \(workout.location.title)")
                LabeledContent("开始", value: workout.startDate.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("结束", value: workout.endDate.formatted(date: .omitted, time: .shortened))
                LabeledContent("运动时长", value: MetricFormatting.clock(seconds: workout.duration))
                if let energy = workout.activeEnergyKilocalories {
                    LabeledContent("活动能量", value: "\(Int(energy.rounded())) 千卡")
                }
                if let distance = workout.distanceMeters {
                    LabeledContent("距离", value: MetricFormatting.distance(meters: distance))
                    if workout.activity == .cycling, let speed = workout.averageSpeedMetersPerSecond {
                        LabeledContent("运动均速", value: "\(MetricFormatting.speedKilometersPerHour(speed)) km/h")
                    }
                    if distance > 0, workout.duration > 0, workout.activity != .cycling {
                        LabeledContent("平均配速", value: Self.pace(seconds: workout.duration, meters: distance))
                    }
                }
                if let average = workout.averageHeartRate {
                    LabeledContent("平均心率", value: "\(Int(average.rounded())) 次/分")
                }
                if let maximum = workout.maximumHeartRate {
                    LabeledContent("最高心率", value: "\(Int(maximum.rounded())) 次/分")
                }
                LabeledContent("来源", value: workout.sourceName)
            }

            Section("心率曲线") {
                LoadStateView(
                    state: viewModel.state,
                    noDataTitle: "没有心率数据",
                    noDataMessage: "这次运动期间没有可读取的心率记录（可能未佩戴 Apple Watch，或未授权读取心率）。",
                    retry: { await viewModel.load() }
                ) { detail in
                    HeartRateCurve(detail: detail)
                        .frame(height: 220)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("workoutDetail.heartRateChart")
                    HStack {
                        stat("最低", detail.statistics.minimum)
                        stat("平均", detail.statistics.average)
                        stat("最高", detail.statistics.maximum)
                    }
                    Text("共 \(detail.sampleCount) 个心率样本")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let note = Self.attributionNote(detail.attribution) {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("workoutDetail.attributionNote")
                    }
                }
            }

            if let detail = viewModel.state.value, !detail.zoneDurations.isEmpty {
                Section {
                    HeartRateZoneBars(durations: detail.zoneDurations)
                } header: {
                    Text("心率区间")
                } footer: {
                    Text("以本次运动最高心率为参照：<60% 热身、60–70% 燃脂、70–80% 有氧、80–90% 无氧、≥90% 极限。")
                }
            }
        }
        .navigationTitle(workout.activity.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if viewModel.state == .idle {
                await viewModel.load()
            }
        }
    }

    private func stat(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text("\(Int(value.rounded())) 次/分").font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 心率曲线不是与该运动关联的样本时，说明数据来源，避免误以为全部来自本次运动。
    static func attributionNote(_ attribution: HeartRateAttribution) -> String? {
        switch attribution {
        case .workoutAssociated:
            return nil
        case .sameDevice:
            return "该运动没有关联心率样本，曲线按运动时间段读取同一设备的心率。"
        case .timeRangeAllSources:
            return "该运动没有关联心率样本，曲线按运动时间段读取所有来源的心率，可能包含其他设备的数据。"
        }
    }

    static func pace(seconds: TimeInterval, meters: Double) -> String {
        let perKilometer = Int((seconds / (meters / 1000)).rounded())
        let secs = perKilometer % 60
        return "\(perKilometer / 60)'\(secs < 10 ? "0" : "")\(secs)\" /公里"
    }
}

private struct HeartRateCurve: View {
    let detail: WorkoutHeartRateDetail

    var body: some View {
        Chart {
            ForEach(detail.points) { point in
                AreaMark(
                    x: .value("时间", point.date),
                    yStart: .value("基线", detail.statistics.minimum - 5),
                    yEnd: .value("心率", point.beatsPerMinute)
                )
                .foregroundStyle(.red.opacity(0.12))
                LineMark(
                    x: .value("时间", point.date),
                    y: .value("心率", point.beatsPerMinute)
                )
                .foregroundStyle(.red)
            }
            RuleMark(y: .value("平均", detail.statistics.average))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .leading) {
                    Text("平均 \(Int(detail.statistics.average.rounded()))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
        }
        .chartYScale(domain: (detail.statistics.minimum - 5)...(detail.statistics.maximum + 5))
        .chartYAxisLabel("次/分")
    }
}

private struct HeartRateZoneBars: View {
    let durations: [HeartRateZone: TimeInterval]

    var body: some View {
        let total = max(durations.values.reduce(0, +), 1)
        VStack(spacing: 8) {
            ForEach(HeartRateZone.allCases.reversed(), id: \.self) { zone in
                let seconds = durations[zone] ?? 0
                HStack {
                    Text(zone.title)
                        .font(.footnote)
                        .frame(width: 36, alignment: .leading)
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color(for: zone))
                            .frame(width: max(2, proxy.size.width * seconds / total))
                    }
                    .frame(height: 10)
                    Text(MetricFormatting.duration(seconds: seconds))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func color(for zone: HeartRateZone) -> Color {
        switch zone {
        case .warmUp: return .blue
        case .fatBurn: return .green
        case .aerobic: return .yellow
        case .anaerobic: return .orange
        case .maximum: return .red
        }
    }
}

#Preview("详情") {
    let service = MockWorkoutHistoryService.demo()
    let workout = SimulatedWorkoutHistory.workouts(endingBefore: .now, count: 1)[0]
    return NavigationStack {
        WorkoutDetailView(viewModel: WorkoutDetailViewModel(workout: workout, service: service))
    }
}
