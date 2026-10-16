import Foundation
import Observation
import WatchPulseShared

/// 运动详情中的运动后反馈结果。
public struct WorkoutFeedbackResult: Hashable, Sendable {
    public let feedback: WorkoutFeedback
    /// 打开的是被合并的确认重复记录时为 `true`：反馈按合并后的主记录计算。
    public let isMergedDuplicate: Bool
    /// 读取条数达到上限，时间窗内更早的同类运动可能没有读到。
    public let mayMissOlderWorkouts: Bool
}

/// 运动后反馈（v0.3 T3）：读取运动记录，与本次之前的可比同类运动比较。只读，不写入 HealthKit。
@MainActor
@Observable
public final class WorkoutFeedbackViewModel {
    public typealias State = LoadState<WorkoutFeedbackResult>

    public let workoutID: UUID
    public private(set) var state: State = .idle

    @ObservationIgnored private let loader: WorkoutAnalysisLoader
    @ObservationIgnored private let fetchLimit: Int
    @ObservationIgnored private let configuration: WorkoutFeedbackConfiguration
    @ObservationIgnored private var isBusy = false

    /// - Parameters:
    ///   - zoneSettings: 用户确认的个人心率区间；`nil` 时不比较区间分布（不推算最大心率）。
    ///   - maximumHeartRateFetches: 最多为本次及更早的多少条同类运动读取心率。
    public init(
        workout: WorkoutRecord,
        service: any WorkoutHistoryService,
        zoneSettings: @escaping @Sendable () -> HeartRateZoneSettings? = { nil },
        fetchLimit: Int = 200,
        maximumHeartRateFetches: Int = 21,
        configuration: WorkoutFeedbackConfiguration = .init()
    ) {
        workoutID = workout.id
        loader = WorkoutAnalysisLoader(service: service, zoneSettings: zoneSettings, maximumHeartRateFetches: maximumHeartRateFetches)
        self.fetchLimit = fetchLimit
        self.configuration = configuration
    }

    public var dataOrigin: HealthDataOrigin { loader.dataOrigin }

    public func load() async {
        guard !isBusy else { return }
        guard loader.isHealthDataAvailable else {
            state = .healthDataUnavailable
            return
        }
        isBusy = true
        defer { isBusy = false }
        if state.value == nil { state = .loading }
        let id = workoutID
        let limit = fetchLimit
        let lookback = configuration.lookback
        let result = await capture { [loader] in
            try await loader.load(limit: limit) { deduplication in
                WorkoutFeedbackViewModel.heartRateTargets(for: id, in: deduplication, lookback: lookback)
            }
        }
        switch result {
        case .success(let set):
            guard let target = set.record(containing: id) else {
                // 不在读取范围内（超过读取上限），或运动已被删除。
                state = .noData
                return
            }
            let feedback = WorkoutFeedbackCalculator.feedback(for: target, among: set.records, configuration: configuration)
            // 读取的原始条数（含被合并的确认重复记录）达到上限时，更早的运动可能没有读到。
            let fetched = set.records.count + set.records.reduce(0) { $0 + $1.mergedWorkoutIDs.count }
            let oldest = set.records.map(\.workout.startDate).min()
            let windowStart = target.workout.startDate.addingTimeInterval(-lookback)
            state = .loaded(WorkoutFeedbackResult(
                feedback: feedback,
                isMergedDuplicate: target.id != id,
                mayMissOlderWorkouts: fetched >= limit && (oldest.map { $0 > windowStart } ?? false)
            ))
        case .failure(let error):
            state = .from(error)
        }
    }

    /// 本次（主记录）在前，其后是时间窗内更早的同类运动（新 → 旧）。
    nonisolated static func heartRateTargets(for workoutID: UUID, in result: WorkoutDeduplicationResult, lookback: TimeInterval) -> [WorkoutRecord] {
        guard let entry = result.entries.first(where: { $0.primary.id == workoutID || $0.mergedDuplicates.contains { $0.id == workoutID } }) else {
            return []
        }
        let target = entry.primary
        let windowStart = target.startDate.addingTimeInterval(-lookback)
        let earlier = result.entries
            .map(\.primary)
            .filter { $0.id != target.id && $0.activity == target.activity }
            .filter { $0.startDate < target.startDate && $0.startDate >= windowStart }
            .sorted { $0.startDate > $1.startDate }
        return [target] + earlier
    }
}
