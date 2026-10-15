import Foundation
import WatchPulseShared

/// 运动记录查询接口。运动由 Apple Watch 的 `HKLiveWorkoutBuilder` 保存到 HealthKit，
/// iPhone 端从 HealthKit 读取（同一 Apple ID 下自动同步）。
public protocol WorkoutHistoryService: Sendable {
    var dataOrigin: HealthDataOrigin { get }
    var isHealthDataAvailable: Bool { get }

    /// 最近的运动，按开始时间倒序。
    func fetchWorkouts(limit: Int) async throws -> [WorkoutRecord]

    /// 该运动的心率曲线（按时间升序），并说明数据归属：
    /// 优先与该运动关联的样本；没有时按时间段读取同一设备的样本；再没有才读取所有来源，并如实标注。
    func fetchHeartRateSeries(for workout: WorkoutRecord) async throws -> WorkoutHeartRateSeries
}

/// 仅用于 Preview、单元测试与演示模式的运动记录服务（模拟数据）。
public final class MockWorkoutHistoryService: WorkoutHistoryService, @unchecked Sendable {
    private let lock = NSLock()
    private var _workouts: MockHealthDataService.Behavior<[WorkoutRecord]>
    private var _heartRates: [UUID: MockHealthDataService.Behavior<[HeartRatePoint]>]
    private var _attributions: [UUID: HeartRateAttribution]
    private var _isHealthDataAvailable: Bool
    private var _workoutFetchCount = 0
    private var _heartRateFetchCount = 0

    public init(
        workouts: MockHealthDataService.Behavior<[WorkoutRecord]> = .noData,
        heartRates: [UUID: MockHealthDataService.Behavior<[HeartRatePoint]>] = [:],
        attributions: [UUID: HeartRateAttribution] = [:],
        isHealthDataAvailable: Bool = true
    ) {
        _workouts = workouts
        _heartRates = heartRates
        _attributions = attributions
        _isHealthDataAvailable = isHealthDataAvailable
    }

    /// 演示模式：最近若干次模拟运动及其心率曲线。
    public static func demo(now: Date = Date(), count: Int = 12) -> MockWorkoutHistoryService {
        let workouts = SimulatedWorkoutHistory.workouts(endingBefore: now, count: count)
        var heartRates: [UUID: MockHealthDataService.Behavior<[HeartRatePoint]>] = [:]
        for workout in workouts {
            heartRates[workout.id] = .value(SimulatedWorkoutHistory.heartRates(for: workout))
        }
        return MockWorkoutHistoryService(workouts: .value(workouts), heartRates: heartRates)
    }

    public var dataOrigin: HealthDataOrigin { .simulated }
    public var isHealthDataAvailable: Bool { withLock { _isHealthDataAvailable } }
    public var workoutFetchCount: Int { withLock { _workoutFetchCount } }
    public var heartRateFetchCount: Int { withLock { _heartRateFetchCount } }

    public func setWorkouts(_ behavior: MockHealthDataService.Behavior<[WorkoutRecord]>) {
        withLock { _workouts = behavior }
    }

    /// 演示模式中把刚完成的模拟运动加入历史。
    public func insert(_ workout: WorkoutRecord, heartRates: [HeartRatePoint]) {
        withLock {
            var current: [WorkoutRecord] = []
            if case .value(let workouts) = _workouts {
                current = workouts
            }
            current.removeAll { $0.id == workout.id }
            current.append(workout)
            _workouts = .value(current.sorted { $0.startDate > $1.startDate })
            _heartRates[workout.id] = .value(heartRates)
        }
    }

    public func fetchWorkouts(limit: Int) async throws -> [WorkoutRecord] {
        let behavior = withLock {
            _workoutFetchCount += 1
            return _workouts
        }
        switch behavior {
        case .value(let workouts): return Array(workouts.sorted { $0.startDate > $1.startDate }.prefix(limit))
        case .noData: return []
        case .failure(let error): throw error
        }
    }

    /// 只返回登记在该运动名下的心率（模拟“与运动关联的样本”），不会混入其他运动的数据。
    public func fetchHeartRateSeries(for workout: WorkoutRecord) async throws -> WorkoutHeartRateSeries {
        let (behavior, attribution) = withLock {
            _heartRateFetchCount += 1
            return (_heartRates[workout.id] ?? .noData, _attributions[workout.id] ?? .workoutAssociated)
        }
        switch behavior {
        case .value(let series):
            let points = series
                .filter { $0.date >= workout.startDate && $0.date <= workout.endDate }
                .sorted { $0.date < $1.date }
            return WorkoutHeartRateSeries(points: points, attribution: attribution)
        case .noData:
            return WorkoutHeartRateSeries(points: [], attribution: attribution)
        case .failure(let error):
            throw error
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// 确定性的模拟运动历史（非真实数据）。
public enum SimulatedWorkoutHistory {
    public static let sourceName = "模拟数据（非真实）"

    public static func workouts(endingBefore now: Date, count: Int) -> [WorkoutRecord] {
        var generator = SeededRandomGenerator(seed: 7)
        let activities: [WorkoutActivityKind] = [.running, .walking, .cycling, .highIntensityIntervalTraining, .running, .walking]
        return (0..<count).map { index in
            let activity = activities[index % activities.count]
            let daysAgo = Double(index) * 1.6 + 0.4
            let start = now.addingTimeInterval(-daysAgo * 86_400 - 3_600)
            let minutes = generator.value(in: 22...65).rounded()
            let duration = minutes * 60
            let average = generator.value(in: 112...152).rounded()
            let distance: Double? = activity.tracksDistance
                ? duration * (activity == .cycling ? 6 : activity == .running ? 2.8 : 1.4)
                : nil
            return WorkoutRecord(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!,
                activity: activity,
                location: activity == .highIntensityIntervalTraining ? .indoor : .outdoor,
                startDate: start,
                endDate: start.addingTimeInterval(duration),
                duration: duration,
                activeEnergyKilocalories: (minutes * generator.value(in: 6...12)).rounded(),
                distanceMeters: distance,
                averageHeartRate: average,
                maximumHeartRate: average + generator.value(in: 18...30).rounded(),
                minimumHeartRate: average - generator.value(in: 25...40).rounded(),
                sourceName: sourceName
            )
        }
    }

    /// 每 5 秒一个点的模拟心率曲线：热身 → 平台 + 波动 → 放松。
    public static func heartRates(for workout: WorkoutRecord) -> [HeartRatePoint] {
        var generator = SeededRandomGenerator(seed: UInt64(workout.startDate.timeIntervalSince1970))
        let average = workout.averageHeartRate ?? 130
        let span = workout.endDate.timeIntervalSince(workout.startDate)
        return stride(from: 0.0, through: span, by: 5).map { offset in
            let progress = offset / max(span, 1)
            let warmUp = min(1, progress * 6)
            let coolDown = progress > 0.9 ? (progress - 0.9) * 4 : 0
            let value = 85 + (average + 6 - 85) * warmUp - 30 * coolDown
                + 8 * sin(offset / 120)
                + generator.value(in: -3...3)
            return HeartRatePoint(date: workout.startDate.addingTimeInterval(offset), beatsPerMinute: value)
        }
    }
}
