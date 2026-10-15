import WatchPulseCore

/// 组装真实依赖的唯一入口。Preview 与单元测试改用 `MockHealthDataService`。
enum AppDependencies {
    static func makeHealthDataService() -> any HealthDataService {
        HealthKitHealthDataService()
    }
}
