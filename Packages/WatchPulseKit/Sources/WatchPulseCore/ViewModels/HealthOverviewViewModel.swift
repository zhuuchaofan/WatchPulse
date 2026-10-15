import Foundation
import Observation
import WatchPulseShared

/// 单项指标卡片的状态。单项失败不影响其他指标显示。
public enum MetricCardStatus: Hashable, Sendable {
    case value(MetricSummaryValue)
    case noData
    case failed(HealthDataError)
}

public struct MetricCardModel: Hashable, Sendable, Identifiable {
    public let kind: HealthMetricKind
    public let status: MetricCardStatus

    public var id: HealthMetricKind { kind }

    public init(kind: HealthMetricKind, status: MetricCardStatus) {
        self.kind = kind
        self.status = status
    }
}

/// 健康总览页的数据。
public struct HealthDashboardSnapshot: Hashable, Sendable {
    /// 最新一条心率（含单位、来源）；没有数据为 `nil`。
    public let latestHeartRate: HeartRateSample?
    /// 心率以外各项指标的卡片。
    public let cards: [MetricCardModel]
    /// 心率读取失败时的错误。
    public let heartRateError: HealthDataError?

    public init(latestHeartRate: HeartRateSample?, cards: [MetricCardModel], heartRateError: HealthDataError? = nil) {
        self.latestHeartRate = latestHeartRate
        self.cards = cards
        self.heartRateError = heartRateError
    }

    public func card(for kind: HealthMetricKind) -> MetricCardModel? {
        cards.first { $0.kind == kind }
    }

    /// 总览卡片中显示的指标（心率单独以大卡片展示）。
    public static let cardKinds: [HealthMetricKind] = [
        .restingHeartRate, .heartRateVariability, .stepCount, .activeEnergy, .sleep,
    ]
}

/// 健康总览页面的 ViewModel：可用性检查 → 授权状态检查 → 按需授权 → 并发读取各项指标。
@MainActor
@Observable
public final class HealthOverviewViewModel {
    public typealias State = LoadState<HealthDashboardSnapshot>

    public private(set) var state: State = .idle
    /// 最近一次成功完成查询（包括无数据）的时间。
    public private(set) var lastCheckedAt: Date?

    private let service: any HealthDataService
    private let now: @Sendable () -> Date
    private var isBusy = false

    public init(
        service: any HealthDataService,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.now = now
    }

    public var dataOrigin: HealthDataOrigin { service.dataOrigin }

    /// 是否正在执行授权或读取。
    public var isLoading: Bool { isBusy }

    /// 页面出现 / 下拉刷新时调用。不会主动弹出授权框。
    public func load() async {
        let day = now()
        await perform { [service] in
            switch try await service.authorizationRequestStatus() {
            case .shouldRequest:
                return .needsAuthorization
            case .unnecessary, .unknown:
                return await Self.fetchState(from: service, day: day)
            }
        }
    }

    /// 用户点击“授权”按钮时调用：弹出系统授权框，结束后立即读取。
    public func requestAuthorizationAndLoad() async {
        let day = now()
        await perform { [service] in
            try await service.requestAuthorization()
            return await Self.fetchState(from: service, day: day)
        }
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
        state = .loading

        do {
            let newState = try await operation()
            switch newState {
            case .loaded, .noData:
                lastCheckedAt = now()
            default:
                break
            }
            state = newState
        } catch {
            state = .from(error)
        }
    }

    nonisolated static func fetchState(from service: any HealthDataService, day: Date) async -> State {
        async let heartRate = capture { try await service.fetchLatestHeartRate() }
        let cards = await withTaskGroup(of: MetricCardModel.self) { group in
            for kind in HealthDashboardSnapshot.cardKinds {
                group.addTask {
                    switch await capture({ try await service.fetchSummary(for: kind, on: day) }) {
                    case .success(let value?): return MetricCardModel(kind: kind, status: .value(value))
                    case .success(nil): return MetricCardModel(kind: kind, status: .noData)
                    case .failure(let error): return MetricCardModel(kind: kind, status: .failed(error))
                    }
                }
            }
            var result: [MetricCardModel] = []
            for await card in group {
                result.append(card)
            }
            return HealthDashboardSnapshot.cardKinds.compactMap { kind in result.first { $0.kind == kind } }
        }

        let heartRateResult = await heartRate
        var errors = cards.compactMap { card -> HealthDataError? in
            if case .failed(let error) = card.status { return error }
            return nil
        }
        let latest: HeartRateSample?
        var heartRateError: HealthDataError?
        switch heartRateResult {
        case .success(let sample):
            latest = sample
        case .failure(let error):
            latest = nil
            heartRateError = error
            errors.append(error)
        }

        // 全部失败：整体视为失败（例如设备锁定）。
        if errors.count == cards.count + 1, let first = errors.first {
            return first == .healthDataUnavailable ? .healthDataUnavailable : .failed(first)
        }
        // 全部无数据：整体视为无数据，而不是“权限被拒绝”。
        let allEmpty = latest == nil && heartRateError == nil && cards.allSatisfy { $0.status == .noData }
        if allEmpty {
            return .noData
        }
        return .loaded(HealthDashboardSnapshot(latestHeartRate: latest, cards: cards, heartRateError: heartRateError))
    }
}

/// 把异步调用结果转换为 `Result`，错误统一映射为 `HealthDataError`。
func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, HealthDataError> {
    do {
        return .success(try await operation())
    } catch let error as HealthDataError {
        return .failure(error)
    } catch {
        return .failure(.queryFailed(reason: error.localizedDescription))
    }
}
