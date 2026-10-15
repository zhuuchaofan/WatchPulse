import Foundation
import Observation
import WatchPulseShared

/// 单项指标历史趋势页的 ViewModel。
@MainActor
@Observable
public final class MetricTrendViewModel {
    public typealias State = LoadState<MetricTrend>

    public let kind: HealthMetricKind
    public private(set) var period: TrendPeriod
    public private(set) var state: State = .idle

    private let service: any HealthDataService
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    /// 用于丢弃过期请求的结果（用户快速切换时间范围时）。
    private var requestToken = 0

    public init(
        kind: HealthMetricKind,
        period: TrendPeriod = .week,
        service: any HealthDataService,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.kind = kind
        self.period = period
        self.service = service
        self.calendar = calendar
        self.now = now
    }

    public var dataOrigin: HealthDataOrigin { service.dataOrigin }

    public func select(_ period: TrendPeriod) async {
        guard period != self.period || state.value == nil else { return }
        self.period = period
        await load()
    }

    public func load() async {
        guard service.isHealthDataAvailable else {
            state = .healthDataUnavailable
            return
        }
        requestToken += 1
        let token = requestToken
        let period = self.period
        let interval = period.interval(endingAt: now(), calendar: calendar)
        state = .loading

        let result = await capture { [service, kind] in
            try await service.fetchDailyTrend(for: kind, in: interval)
        }
        guard token == requestToken else { return }

        switch result {
        case .success(let points) where points.isEmpty:
            state = .noData
        case .success(let points):
            state = .loaded(MetricTrend(kind: kind, period: period, interval: interval, points: points))
        case .failure(let error):
            state = .from(error)
        }
    }
}
