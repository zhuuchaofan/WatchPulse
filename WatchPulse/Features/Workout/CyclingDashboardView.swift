import SwiftUI
import WatchPulseCore
import WatchPulseShared

/// iPhone 骑行码表（竖屏）：大号当前速度、来源与有效性、运动均速、距离、时间、心率与区间。
///
/// 速度缺失 / 过期 / 暂停 / 断开时显示 `--` 并说明原因，不显示 0。骑行中请勿操作手机。
struct CyclingDashboardPanel: View {
    let monitor: LiveWorkoutMonitor
    /// 大字模式：只保留速度、心率与关键数据，字号更大。
    let isLargeMode: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let display = CyclingDisplayModel(
                configuration: monitor.configuration,
                metrics: monitor.latestMetrics,
                phase: monitor.phase,
                zones: monitor.heartRateZones,
                targetZone: monitor.targetZone,
                isLinkHealthy: monitor.isConnected,
                now: context.date
            )
            VStack(spacing: isLargeMode ? 20 : 14) {
                speed(display)
                stats(display, elapsed: monitor.elapsedTime(at: context.date))
                ZoneBar(zones: display.zones, current: display.zone, target: display.targetZone, text: display.zoneText)
            }
        }
    }

    private func speed(_ display: CyclingDisplayModel) -> some View {
        VStack(spacing: 2) {
            Text(display.speedText)
                .font(.system(size: isLargeMode ? 120 : 84, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(display.isSpeedLive ? .primary : .secondary)
                .accessibilityIdentifier("cycling.speed")
                .accessibilityLabel("当前速度 \(display.speedText) 千米每小时")
            Text("km/h  当前速度")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label(display.speedStatusText, systemImage: display.isSpeedLive ? "location.fill" : "location.slash")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(display.isSpeedLive ? Color.green : Color.orange)
                .accessibilityIdentifier("cycling.speedStatus")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func stats(_ display: CyclingDisplayModel, elapsed: TimeInterval) -> some View {
        let valueFont: Font = isLargeMode ? .system(size: 34, weight: .bold, design: .rounded) : .title2.weight(.bold)
        return Grid(horizontalSpacing: 16, verticalSpacing: 14) {
            GridRow {
                stat("运动均速", display.averageSpeedText, unit: "km/h", font: valueFont)
                    .accessibilityIdentifier("cycling.averageSpeed")
                stat("距离", display.distanceText, unit: "", font: valueFont)
            }
            GridRow {
                stat("时间", MetricFormatting.clock(seconds: elapsed), unit: "", font: valueFont)
                stat("心率", display.heartRateText, unit: "次/分", font: valueFont)
                    .accessibilityIdentifier("cycling.heartRate")
            }
        }
    }

    private func stat(_ title: String, _ value: String, unit: String, font: Font) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(font).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
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
}

/// Z1–Z5 区间条：高亮当前区间，标出目标区间。
struct ZoneBar: View {
    let zones: HeartRateZoneSettings?
    let current: TrainingZone?
    let target: TrainingZone?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("心率区间").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(text).font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("cycling.zone")
            }
            HStack(spacing: 4) {
                ForEach(TrainingZone.allCases) { zone in
                    VStack(spacing: 2) {
                        Text(zone.title)
                            .font(.caption.weight(zone == current ? .bold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(color(zone).opacity(zone == current ? 0.9 : 0.2), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(zone == current ? Color.white : Color.primary)
                            .overlay {
                                if zone == target {
                                    RoundedRectangle(cornerRadius: 6).stroke(Color.primary, lineWidth: 2)
                                }
                            }
                        if let zones {
                            Text("\(zones.lowerBound(of: zone))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .opacity(zones == nil ? 0.4 : 1)
            Text(zones == nil
                 ? "在 Apple Watch 的 WatchPulse › 心率区间与提醒 中设置最大心率后显示区间。"
                 : "区间按你在 Apple Watch 上设置的最大心率 / 下限计算，仅作训练参考。" + (target.map { " 目标 \($0.title)（已开启震动提醒）。" } ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func color(_ zone: TrainingZone) -> Color {
        switch zone {
        case .z1: return .blue
        case .z2: return .green
        case .z3: return .yellow
        case .z4: return .orange
        case .z5: return .red
        }
    }
}
