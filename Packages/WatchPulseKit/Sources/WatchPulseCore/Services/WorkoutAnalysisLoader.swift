import Foundation
import WatchPulseShared

/// 在现有 `WorkoutHistoryService` 之上构建运动分析集合：读取运动 → 去重 → 只为主记录读取心率 → 分析。
///
/// 只读：不写入、不删除任何 HealthKit 数据。不重写查询层；心率读取有数量与并发上限，
/// 单次读取失败只让该条记录的心率降级为“未读取”，不影响次数 / 时长等其他统计。
public struct WorkoutAnalysisLoader: Sendable {
    private let service: any WorkoutHistoryService
    private let zoneSettings: @Sendable () -> HeartRateZoneSettings?
    private let maximumHeartRateFetches: Int
    private let maximumConcurrentFetches: Int
    private let configuration: WorkoutAnalysisConfiguration

    /// - Parameters:
    ///   - zoneSettings: 用户确认的个人心率区间；返回 `nil` 时不生成个人区间分布（不推算最大心率）。
    ///   - maximumHeartRateFetches: 最多为最近多少条运动读取心率。
    public init(
        service: any WorkoutHistoryService,
        zoneSettings: @escaping @Sendable () -> HeartRateZoneSettings? = { nil },
        maximumHeartRateFetches: Int = 30,
        maximumConcurrentFetches: Int = 4,
        configuration: WorkoutAnalysisConfiguration = .init()
    ) {
        self.service = service
        self.zoneSettings = zoneSettings
        self.maximumHeartRateFetches = max(0, maximumHeartRateFetches)
        self.maximumConcurrentFetches = max(1, maximumConcurrentFetches)
        self.configuration = configuration
    }

    public var dataOrigin: HealthDataOrigin { service.dataOrigin }
    public var isHealthDataAvailable: Bool { service.isHealthDataAvailable }

    public func load(limit: Int) async throws -> WorkoutAnalysisSet {
        let workouts = try await service.fetchWorkouts(limit: limit)
        let deduplication = WorkoutDeduplicator.deduplicate(workouts, configuration: configuration.deduplication)
        let targets = deduplication.entries.prefix(maximumHeartRateFetches).map(\.primary)
        let series = try await fetchHeartRates(for: targets)
        return WorkoutAnalysisBuilder.build(
            deduplication: deduplication,
            heartRates: series,
            origin: service.dataOrigin,
            zoneSettings: zoneSettings(),
            configuration: configuration
        )
    }

    private func fetchHeartRates(for workouts: [WorkoutRecord]) async throws -> [UUID: WorkoutHeartRateSeries] {
        guard !workouts.isEmpty else { return [:] }
        let service = service
        let limit = maximumConcurrentFetches
        return try await withThrowingTaskGroup(of: (UUID, WorkoutHeartRateSeries?).self) { group in
            var result: [UUID: WorkoutHeartRateSeries] = [:]
            var iterator = workouts.makeIterator()
            func addNext(_ group: inout ThrowingTaskGroup<(UUID, WorkoutHeartRateSeries?), Error>) {
                guard let workout = iterator.next() else { return }
                group.addTask {
                    do {
                        return (workout.id, try await service.fetchHeartRateSeries(for: workout))
                    } catch {
                        // 取消要向上传播；其他错误只让这一条的心率降级为“未读取”。
                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                        return (workout.id, nil)
                    }
                }
            }
            for _ in 0..<min(limit, workouts.count) { addNext(&group) }
            while let (id, series) = try await group.next() {
                if let series { result[id] = series }
                addNext(&group)
            }
            return result
        }
    }
}
