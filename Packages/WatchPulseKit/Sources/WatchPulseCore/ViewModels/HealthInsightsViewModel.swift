import Foundation
import Observation
import WatchPulseShared

/// 分析页单张卡片的状态。单项失败不影响其他卡片。
public enum InsightCardState<Value: Hashable & Sendable>: Hashable, Sendable {
    case value(Value)
    /// 没有可读取的数据（可能确实没有记录，也可能未授予读取权限，HealthKit 不区分）。
    case noData
    case failed(HealthDataError)

    public var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }
}

/// 分析页的数据。
public struct HealthInsightsSnapshot: Hashable, Sendable {
    public let restingHeartRate: InsightCardState<BaselineComparison>
    public let heartRateVariability: InsightCardState<BaselineComparison>
    public let sleep: InsightCardState<SleepInsight>
    /// 每日序列（参考期 + 观察期），用于趋势图。睡眠为每晚时长（小时）。
    public let series: [HealthMetricKind: DailyMetricSeries]
    public let windows: BaselineWindows
    public let generatedAt: Date

    public init(
        restingHeartRate: InsightCardState<BaselineComparison>,
        heartRateVariability: InsightCardState<BaselineComparison>,
        sleep: InsightCardState<SleepInsight>,
        series: [HealthMetricKind: DailyMetricSeries],
        windows: BaselineWindows,
        generatedAt: Date
    ) {
        self.restingHeartRate = restingHeartRate
        self.heartRateVariability = heartRateVariability
        self.sleep = sleep
        self.series = series
        self.windows = windows
        self.generatedAt = generatedAt
    }
}

/// 趋势图范围。
public enum InsightTrendRange: Int, CaseIterable, Hashable, Sendable, Identifiable {
    case week = 7
    case fourWeeks = 28

    public var id: Int { rawValue }
    public var title: String { self == .week ? "7 天" : "28 天" }
}

/// 分析页 ViewModel：可用性检查 → 授权状态 → 并发读取静息心率 / HRV 的 35 天日值与近 14 晚睡眠 → 计算基线与睡眠分析。
///
/// 只计算，不缓存：35 天日值查询量很小；若真机上明显变慢再加本地缓存（路线图 H5）。
@MainActor
@Observable
public final class HealthInsightsViewModel {
    public typealias State = LoadState<HealthInsightsSnapshot>

    public static let baselineKinds: [HealthMetricKind] = [.restingHeartRate, .heartRateVariability]

    public private(set) var state: State = .idle
    public var trendRange: InsightTrendRange = .week

    @ObservationIgnored private let service: any HealthDataService
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var isBusy = false

    public init(
        service: any HealthDataService,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.calendar = calendar
        self.now = now
    }

    public var dataOrigin: HealthDataOrigin { service.dataOrigin }

    /// 页面出现 / 下拉刷新时调用。不会主动弹出授权框。
    public func load() async {
        await perform { [service, calendar, now] in
            switch try await service.authorizationRequestStatus() {
            case .shouldRequest:
                return .needsAuthorization
            case .unnecessary, .unknown:
                return await Self.fetchState(from: service, now: now(), calendar: calendar)
            }
        }
    }

    /// 用户点击“授权”按钮时调用。
    public func requestAuthorizationAndLoad() async {
        await perform { [service, calendar, now] in
            try await service.requestAuthorization()
            return await Self.fetchState(from: service, now: now(), calendar: calendar)
        }
    }

    /// 趋势图数据：截至今天（含）的最近 `trendRange` 天，缺测日为 `nil`。
    public func trendDays(for kind: HealthMetricKind) -> [DailyMetricValue] {
        guard let series = state.value?.series[kind] else { return [] }
        return Array(series.days.suffix(trendRange.rawValue))
    }

    // MARK: - Private

    private func perform(_ operation: @Sendable () async throws -> State) async {
        guard !isBusy else { return }
        guard service.isHealthDataAvailable else {
            state = .healthDataUnavailable
            return
        }
        isBusy = true
        defer { isBusy = false }
        if state.value == nil {
            state = .loading
        }
        do {
            state = try await operation()
        } catch {
            state = .from(error)
        }
    }

    nonisolated static func fetchState(from service: any HealthDataService, now: Date, calendar: Calendar) async -> State {
        let windows = BaselineWindows(asOf: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        // 趋势图含今天，基线计算只用完整日（`BaselineComparison` 内部按窗口截取）。
        let seriesInterval = DateInterval(start: windows.reference.start, end: calendar.date(byAdding: .day, value: 1, to: today)!)
        let sleepInterval = DateInterval(
            start: calendar.date(byAdding: .day, value: -(SleepInsight.regularityDays - 1), to: today)!,
            end: seriesInterval.end
        )
        let sleepChartInterval = DateInterval(start: windows.reference.start, end: seriesInterval.end)

        async let restingResult = capture { try await service.fetchDailyTrend(for: .restingHeartRate, in: seriesInterval) }
        async let hrvResult = capture { try await service.fetchDailyTrend(for: .heartRateVariability, in: seriesInterval) }
        async let sleepResult = capture { try await service.fetchSleepNights(in: sleepChartInterval) }

        var series: [HealthMetricKind: DailyMetricSeries] = [:]
        func baseline(_ kind: HealthMetricKind, _ result: Result<[MetricDataPoint], HealthDataError>) -> InsightCardState<BaselineComparison> {
            switch result {
            case .failure(let error):
                return .failed(error)
            case .success(let points):
                let daily = DailyMetricSeries(kind: kind, points: points, interval: seriesInterval, calendar: calendar)
                series[kind] = daily
                guard daily.validDayCount > 0 else { return .noData }
                return .value(BaselineComparison(kind: kind, daily: daily, windows: windows))
            }
        }
        let resting = baseline(.restingHeartRate, await restingResult)
        let hrv = baseline(.heartRateVariability, await hrvResult)

        let sleep: InsightCardState<SleepInsight>
        switch await sleepResult {
        case .failure(let error):
            sleep = .failed(error)
        case .success(let nights):
            series[.sleep] = DailyMetricSeries(
                kind: .sleep,
                points: nights.map { MetricDataPoint(date: $0.date, value: $0.primaryDuration / 3_600) },
                interval: sleepChartInterval,
                calendar: calendar
            )
            let recent = nights.filter { sleepInterval.contains($0.date) }
            let insight = SleepInsight(nights: recent, now: now, calendar: calendar)
            sleep = insight.latestNight == nil ? .noData : .value(insight)
        }

        let failures: [HealthDataError] = [resting, hrv].compactMap {
            if case .failed(let error) = $0 { return error }
            return nil
        } + (sleep.failure.map { [$0] } ?? [])
        if failures.count == 3, let first = failures.first {
            return first == .healthDataUnavailable ? .healthDataUnavailable : .failed(first)
        }
        if resting == .noData, hrv == .noData, sleep == .noData {
            return .noData
        }
        return .loaded(HealthInsightsSnapshot(
            restingHeartRate: resting,
            heartRateVariability: hrv,
            sleep: sleep,
            series: series,
            windows: windows,
            generatedAt: now
        ))
    }
}

extension InsightCardState {
    var failure: HealthDataError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}
