import WatchPulseShared

/// 各页面通用的加载状态。
public enum LoadState<Value: Hashable & Sendable>: Hashable, Sendable {
    /// 尚未开始加载。
    case idle
    /// 正在加载。
    case loading
    /// 设备不支持 HealthKit。
    case healthDataUnavailable
    /// 尚未请求过授权，需要用户主动触发。
    case needsAuthorization
    /// 查询成功但没有可读取的数据（可能确实没有，也可能未授予读取权限，HealthKit 不区分）。
    case noData
    /// 加载失败。
    case failed(HealthDataError)
    /// 加载成功。
    case loaded(Value)

    public var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    public var isLoading: Bool {
        switch self {
        case .idle, .loading: return true
        default: return false
        }
    }

    /// 把错误映射为状态：设备不支持单独处理。
    static func from(_ error: Error) -> LoadState {
        let mapped = (error as? HealthDataError) ?? .queryFailed(reason: error.localizedDescription)
        return mapped == .healthDataUnavailable ? .healthDataUnavailable : .failed(mapped)
    }
}
