import Foundation
import Observation
import WatchPulseShared

/// 运动分析集合的加载状态（T1 数据层的入口；T2–T4 在其上构建目标、反馈与进步分析）。
@MainActor
@Observable
public final class WorkoutAnalysisViewModel {
    public typealias State = LoadState<WorkoutAnalysisSet>

    public private(set) var state: State = .idle
    public let limit: Int

    private let loader: WorkoutAnalysisLoader
    private var isBusy = false

    public init(loader: WorkoutAnalysisLoader, limit: Int = 100) {
        self.loader = loader
        self.limit = limit
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
        switch await capture({ [loader, limit] in try await loader.load(limit: limit) }) {
        case .success(let set) where set.records.isEmpty:
            state = .noData
        case .success(let set):
            state = .loaded(set)
        case .failure(let error):
            state = .from(error)
        }
    }
}
