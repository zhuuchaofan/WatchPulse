import Foundation
import WatchPulseShared

/// 健康数据访问接口。ViewModel 只依赖此协议，便于用 `MockHealthDataService` 做 Preview 与单元测试。
public protocol HealthDataService: Sendable {
    /// 数据来源。模拟实现必须返回 `.simulated`，界面据此标注“模拟数据”。
    var dataOrigin: HealthDataOrigin { get }

    /// 当前设备是否支持 HealthKit（`HKHealthStore.isHealthDataAvailable()`）。
    var isHealthDataAvailable: Bool { get }

    /// 是否需要弹出授权框。不会触发任何系统 UI。
    func authorizationRequestStatus() async throws -> HealthAuthorizationRequestStatus

    /// 请求授权（按需调用，会弹出系统授权框）。
    ///
    /// 成功返回只代表授权流程结束，**不代表**用户允许了读取。
    func requestAuthorization() async throws

    /// 读取最新一条心率记录（按采样结束时间倒序取第一条）。
    ///
    /// - Returns: 没有可读取记录时返回 `nil`。读取权限被拒绝时 HealthKit 也会返回空结果。
    func fetchLatestHeartRate() async throws -> HeartRateSample?

    /// 指标摘要：离散指标为最新值，累计指标为 `day` 当天合计，睡眠为 `day` 醒来的那一夜。
    ///
    /// - Returns: 没有数据时返回 `nil`。
    func fetchSummary(for kind: HealthMetricKind, on day: Date) async throws -> MetricSummaryValue?

    /// 按天聚合的趋势数据，只返回有数据的天。睡眠的数值单位为小时。
    func fetchDailyTrend(for kind: HealthMetricKind, in interval: DateInterval) async throws -> [MetricDataPoint]
}
