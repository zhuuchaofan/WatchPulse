import WatchPulseShared

/// 健康数据访问接口。ViewModel 只依赖此协议，便于用 `MockHealthDataService` 做 Preview 与单元测试。
public protocol HealthDataService: Sendable {
    /// 当前设备是否支持 HealthKit（`HKHealthStore.isHealthDataAvailable()`）。
    var isHealthDataAvailable: Bool { get }

    /// 是否需要弹出授权框。不会触发任何系统 UI。
    func authorizationRequestStatus() async throws -> HealthAuthorizationRequestStatus

    /// 请求读取心率的授权（按需调用，会弹出系统授权框）。
    ///
    /// 成功返回只代表授权流程结束，**不代表**用户允许了读取。
    func requestAuthorization() async throws

    /// 读取最新一条心率记录（按采样结束时间倒序取第一条）。
    ///
    /// - Returns: 没有可读取记录时返回 `nil`。读取权限被拒绝时 HealthKit 也会返回空结果。
    func fetchLatestHeartRate() async throws -> HeartRateSample?
}
