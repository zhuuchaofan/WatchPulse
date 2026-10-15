import Foundation
import Observation
import WatchPulseShared

/// 健康总览页面的 ViewModel：负责可用性检查 → 授权状态检查 → 按需授权 → 读取最新心率。
@MainActor
@Observable
public final class HealthOverviewViewModel {
    public enum State: Hashable, Sendable {
        /// 尚未开始加载。
        case idle
        /// 正在检查授权状态或读取数据。
        case loading
        /// 设备不支持 HealthKit。
        case healthDataUnavailable
        /// 尚未请求过授权，需要用户点击按钮触发系统授权框。
        case needsAuthorization
        /// 查询成功但没有可读取的记录（可能确实没有，也可能未授予读取权限，HealthKit 不区分）。
        case noData
        /// 授权或查询失败。
        case failed(HealthDataError)
        /// 读取成功。
        case loaded(HeartRateSample)
    }

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

    /// 是否正在执行授权或读取。
    public var isLoading: Bool {
        isBusy
    }

    /// 页面出现 / 下拉刷新时调用。不会主动弹出授权框。
    public func load() async {
        await perform { [service] in
            switch try await service.authorizationRequestStatus() {
            case .shouldRequest:
                return .needsAuthorization
            case .unnecessary, .unknown:
                return try await Self.fetchState(from: service)
            }
        }
    }

    /// 用户点击“授权”按钮时调用：弹出系统授权框，结束后立即读取。
    public func requestAuthorizationAndLoad() async {
        await perform { [service] in
            try await service.requestAuthorization()
            return try await Self.fetchState(from: service)
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
            if newState != .needsAuthorization {
                lastCheckedAt = now()
            }
            state = newState
        } catch let error as HealthDataError {
            state = error == .healthDataUnavailable ? .healthDataUnavailable : .failed(error)
        } catch {
            state = .failed(.queryFailed(reason: error.localizedDescription))
        }
    }

    private nonisolated static func fetchState(from service: any HealthDataService) async throws -> State {
        if let sample = try await service.fetchLatestHeartRate() {
            return .loaded(sample)
        }
        return .noData
    }
}
