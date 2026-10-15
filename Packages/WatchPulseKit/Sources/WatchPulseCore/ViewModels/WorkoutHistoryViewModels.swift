import Foundation
import Observation
import WatchPulseShared

/// 运动记录列表。
@MainActor
@Observable
public final class WorkoutHistoryViewModel {
    public typealias State = LoadState<[WorkoutRecord]>

    public private(set) var state: State = .idle
    public let limit: Int

    private let service: any WorkoutHistoryService
    private var isBusy = false

    public init(service: any WorkoutHistoryService, limit: Int = 100) {
        self.service = service
        self.limit = limit
    }

    public var dataOrigin: HealthDataOrigin { service.dataOrigin }

    public func load() async {
        guard !isBusy else { return }
        guard service.isHealthDataAvailable else {
            state = .healthDataUnavailable
            return
        }
        isBusy = true
        defer { isBusy = false }
        if state.value == nil {
            state = .loading
        }
        switch await capture({ [service, limit] in try await service.fetchWorkouts(limit: limit) }) {
        case .success(let workouts) where workouts.isEmpty:
            state = .noData
        case .success(let workouts):
            state = .loaded(workouts)
        case .failure(let error):
            state = .from(error)
        }
    }

    /// 按月分组（最新的月份在前）。
    public static func groupedByMonth(_ workouts: [WorkoutRecord], calendar: Calendar = .current) -> [(month: Date, workouts: [WorkoutRecord])] {
        let groups = Dictionary(grouping: workouts) { workout in
            calendar.date(from: calendar.dateComponents([.year, .month], from: workout.startDate))!
        }
        return groups
            .map { (month: $0.key, workouts: $0.value.sorted { $0.startDate > $1.startDate }) }
            .sorted { $0.month > $1.month }
    }
}

/// 运动详情中的心率曲线数据。
public struct WorkoutHeartRateDetail: Hashable, Sendable {
    /// 降采样后的曲线点。
    public let points: [HeartRatePoint]
    public let statistics: HeartRateSeriesStatistics
    /// 原始样本数。
    public let sampleCount: Int
    /// 各心率区间的时长（秒）。
    public let zoneDurations: [HeartRateZone: TimeInterval]
}

/// 以本次运动最高心率为参照的简单心率区间（不需要年龄等个人信息）。
public enum HeartRateZone: Int, CaseIterable, Comparable, Sendable {
    case warmUp = 1
    case fatBurn
    case aerobic
    case anaerobic
    case maximum

    public var title: String {
        switch self {
        case .warmUp: return "热身"
        case .fatBurn: return "燃脂"
        case .aerobic: return "有氧"
        case .anaerobic: return "无氧"
        case .maximum: return "极限"
        }
    }

    /// 占本次最高心率的比例下限。
    var lowerBound: Double {
        switch self {
        case .warmUp: return 0
        case .fatBurn: return 0.6
        case .aerobic: return 0.7
        case .anaerobic: return 0.8
        case .maximum: return 0.9
        }
    }

    public static func < (lhs: HeartRateZone, rhs: HeartRateZone) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func zone(for value: Double, maximum: Double) -> HeartRateZone {
        let ratio = maximum > 0 ? value / maximum : 0
        return allCases.last { ratio >= $0.lowerBound } ?? .warmUp
    }

    /// 相邻样本之间的时长计入前一个样本的区间；超过 `maxGap` 的间隔视为缺测不计入。
    public static func durations(for points: [HeartRatePoint], maxGap: TimeInterval = 60) -> [HeartRateZone: TimeInterval] {
        let sorted = points.sorted { $0.date < $1.date }
        guard let maximum = sorted.map(\.beatsPerMinute).max() else { return [:] }
        var result: [HeartRateZone: TimeInterval] = [:]
        for (current, next) in zip(sorted, sorted.dropFirst()) {
            let gap = next.date.timeIntervalSince(current.date)
            guard gap > 0, gap <= maxGap else { continue }
            result[zone(for: current.beatsPerMinute, maximum: maximum), default: 0] += gap
        }
        return result
    }
}

/// 单次运动详情：读取运动期间的心率曲线。
@MainActor
@Observable
public final class WorkoutDetailViewModel {
    public typealias State = LoadState<WorkoutHeartRateDetail>

    public let workout: WorkoutRecord
    public private(set) var state: State = .idle

    private let service: any WorkoutHistoryService
    private let maxChartPoints: Int

    public init(workout: WorkoutRecord, service: any WorkoutHistoryService, maxChartPoints: Int = 300) {
        self.workout = workout
        self.service = service
        self.maxChartPoints = maxChartPoints
    }

    public var dataOrigin: HealthDataOrigin { service.dataOrigin }

    public func load() async {
        guard service.isHealthDataAvailable else {
            state = .healthDataUnavailable
            return
        }
        state = .loading
        let workout = workout
        switch await capture({ [service] in try await service.fetchHeartRateSeries(from: workout.startDate, to: workout.endDate) }) {
        case .success(let points):
            guard let statistics = HeartRateSeriesStatistics(points: points) else {
                state = .noData
                return
            }
            state = .loaded(WorkoutHeartRateDetail(
                points: HeartRateSeries.downsample(points, maxPoints: maxChartPoints),
                statistics: statistics,
                sampleCount: points.count,
                zoneDurations: HeartRateZone.durations(for: points)
            ))
        case .failure(let error):
            state = .from(error)
        }
    }
}
