import Foundation
import WatchPulseShared

/// 模拟的运动驱动：用于单元测试、Preview、模拟器与演示模式。
///
/// 生成的心率、能量、距离均为**确定性的合成数据**（非真实健康数据），`dataOrigin` 为 `.simulated`，
/// 结束时返回的运动记录来源名为 `sourceName`，不会写入 HealthKit。
@MainActor
public final class SimulatedWorkoutSessionDriver: WorkoutSessionDriver {
    public static let sourceName = "模拟运动（非真实）"

    public var eventHandler: ((WorkoutDriverEvent) -> Void)?
    public let dataOrigin: HealthDataOrigin = .simulated

    // MARK: 故障注入

    public var authorizationError: WorkoutSessionError?
    public var startError: WorkoutSessionError?
    public var endError: WorkoutSessionError?
    /// 开始时镜像失败（运动仍会开始）。
    public var failMirroringOnStart = false
    /// 重连镜像的实现；为 `nil` 时视为重连成功。演示模式中接到 `InMemoryMirroringLink.reconnect()`。
    public var mirroringReconnector: (() throws -> Void)?
    /// `recoverActiveSession()` 返回的快照，用于测试崩溃恢复。
    public var recoverableSnapshot: WorkoutStateSnapshot?

    // MARK: 状态

    public private(set) var phase: WorkoutSessionPhase = .notStarted
    public private(set) var reconnectAttempts = 0
    private var configuration: WorkoutConfigurationRequest?
    private var startDate: Date?
    private var activeTime: TimeInterval = 0
    private var lastAdvanceAt: Date?
    private var energy: Double = 0
    private var distance: Double = 0
    private var heartRates: [Double] = []
    private var generator = SeededRandomGenerator(seed: 2024)

    public init() {}

    public func requestAuthorization() async throws {
        if let authorizationError { throw authorizationError }
    }

    public func start(_ configuration: WorkoutConfigurationRequest, at date: Date) async throws {
        guard !phase.isActive else { throw WorkoutSessionError.invalidTransition(from: phase, action: "开始") }
        if let startError { throw startError }
        self.configuration = configuration
        startDate = date
        activeTime = 0
        energy = 0
        distance = 0
        heartRates = []
        lastAdvanceAt = date
        if failMirroringOnStart {
            eventHandler?(.mirroringDisconnected(reason: "模拟：镜像启动失败"))
        }
        setPhase(.running, at: date)
    }

    /// 推进模拟时钟，生成一条指标。
    public func advance(to date: Date) {
        guard phase == .running, let lastAdvanceAt, let configuration, date > lastAdvanceAt else { return }
        let delta = date.timeIntervalSince(lastAdvanceAt)
        self.lastAdvanceAt = date
        activeTime += delta

        let profile = Self.profile(for: configuration.activity)
        energy += profile.kilocaloriesPerMinute * delta / 60
        if configuration.activity.tracksDistance {
            distance += profile.metersPerSecond * delta
        }
        let warmUp = min(1, activeTime / 180)
        let heartRate = 90 + (profile.heartRate - 90) * warmUp
            + 6 * sin(activeTime / 75)
            + generator.value(in: -2.5...2.5)
        heartRates.append(heartRate)

        eventHandler?(.metrics(WorkoutMetricsSnapshot(
            timestamp: date,
            elapsedTime: activeTime,
            heartRateBPM: heartRate,
            activeEnergyKilocalories: energy,
            distanceMeters: configuration.activity.tracksDistance ? distance : nil
        )))
    }

    public func pause(at date: Date) {
        guard phase == .running else { return }
        advance(to: date)
        lastAdvanceAt = nil
        setPhase(.paused, at: date)
    }

    public func resume(at date: Date) {
        guard phase == .paused else { return }
        lastAdvanceAt = date
        setPhase(.running, at: date)
    }

    public func end(at date: Date) async throws -> WorkoutRecord? {
        guard phase.isActive, let configuration, let startDate else { throw WorkoutSessionError.noActiveSession }
        advance(to: date)
        lastAdvanceAt = nil
        setPhase(.ended, at: date)
        if let endError { throw endError }
        let statistics = HeartRateSeriesStatistics(points: heartRates.enumerated().map {
            HeartRatePoint(date: startDate.addingTimeInterval(Double($0.offset)), beatsPerMinute: $0.element)
        })
        return WorkoutRecord(
            id: UUID(),
            activity: configuration.activity,
            location: configuration.location,
            startDate: startDate,
            endDate: date,
            duration: activeTime,
            activeEnergyKilocalories: energy,
            distanceMeters: configuration.activity.tracksDistance ? distance : nil,
            averageHeartRate: statistics?.average,
            maximumHeartRate: statistics?.maximum,
            minimumHeartRate: statistics?.minimum,
            sourceName: Self.sourceName
        )
    }

    public func reconnectMirroring() async throws {
        reconnectAttempts += 1
        try mirroringReconnector?()
    }

    public func recoverActiveSession() async throws -> WorkoutStateSnapshot? {
        guard let snapshot = recoverableSnapshot, snapshot.phase.isActive else { return nil }
        recoverableSnapshot = nil
        configuration = snapshot.configuration
        startDate = snapshot.startDate
        activeTime = snapshot.metrics?.elapsedTime ?? 0
        energy = snapshot.metrics?.activeEnergyKilocalories ?? 0
        distance = snapshot.metrics?.distanceMeters ?? 0
        phase = snapshot.phase
        lastAdvanceAt = snapshot.phase == .running ? snapshot.metrics?.timestamp : nil
        return snapshot
    }

    /// 模拟收到 iPhone 发来的数据。
    public func deliverRemoteData(_ data: Data) {
        eventHandler?(.remoteDataReceived(data))
    }

    /// 模拟系统通知镜像断开。
    public func simulateMirroringDisconnect(reason: String?) {
        eventHandler?(.mirroringDisconnected(reason: reason))
    }

    // MARK: - Private

    private func setPhase(_ newPhase: WorkoutSessionPhase, at date: Date) {
        phase = newPhase
        eventHandler?(.phaseChanged(newPhase, at: date))
    }

    private struct Profile {
        let heartRate: Double
        let kilocaloriesPerMinute: Double
        let metersPerSecond: Double
    }

    private static func profile(for activity: WorkoutActivityKind) -> Profile {
        switch activity {
        case .running: return Profile(heartRate: 148, kilocaloriesPerMinute: 11, metersPerSecond: 2.8)
        case .walking: return Profile(heartRate: 105, kilocaloriesPerMinute: 5, metersPerSecond: 1.4)
        case .cycling: return Profile(heartRate: 132, kilocaloriesPerMinute: 9, metersPerSecond: 6)
        case .highIntensityIntervalTraining: return Profile(heartRate: 158, kilocaloriesPerMinute: 13, metersPerSecond: 0)
        case .other: return Profile(heartRate: 120, kilocaloriesPerMinute: 7, metersPerSecond: 0)
        }
    }
}
