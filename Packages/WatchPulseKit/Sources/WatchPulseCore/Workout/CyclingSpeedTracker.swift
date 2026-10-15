import Foundation
import WatchPulseShared

/// Watch 端骑行测速：只在**室外骑行**时启动定位，把过滤后的速度补充到运动指标中。
///
/// - 不创建、不控制运动会话；Watch 的 `HKWorkoutSession` 仍是计时与状态的唯一来源；
/// - 定位未授权 / 失败时只是没有速度（`.notAuthorized` / `.unavailable`），心率、时长、距离照常记录；
/// - 有新的有效速度时通过 `onUpdate` 请求状态机重发指标（限频）。
@MainActor
public final class CyclingSpeedTracker: WorkoutLiveObserver {
    /// 新速度可用（或质量变化）时调用，通常接到 `WorkoutSessionController.refreshMetrics()`。
    public var onUpdate: (() -> Void)?
    public private(set) var isActive = false

    private let provider: any LocationFixProvider
    private let now: () -> Date
    private let minimumUpdateInterval: TimeInterval
    private var calculator: GPSSpeedCalculator
    private var lastUpdateAt: Date?
    private var lastPublishedQuality: SpeedQuality?

    public init(
        provider: any LocationFixProvider,
        configuration: GPSSpeedCalculator.Configuration = .init(),
        minimumUpdateInterval: TimeInterval = 1,
        now: @escaping () -> Date = { Date() }
    ) {
        self.provider = provider
        self.now = now
        self.minimumUpdateInterval = minimumUpdateInterval
        calculator = GPSSpeedCalculator(configuration: configuration)
        provider.fixHandler = { [weak self] fix in self?.handle(fix) }
        provider.authorizationHandler = { [weak self] status in self?.handleAuthorization(status) }
    }

    public var dataOrigin: HealthDataOrigin { provider.dataOrigin }

    /// 只有室外骑行使用 GPS 测速。
    public static func appliesTo(_ configuration: WorkoutConfigurationRequest) -> Bool {
        configuration.activity == .cycling && configuration.location == .outdoor
    }

    /// 当前速度读数；未启用时为 `nil`。
    public func currentSample() -> WorkoutSpeedSample? {
        isActive ? calculator.sample(at: now()) : nil
    }

    /// 由 App 每秒调用：速度质量变化（例如过期）时即使没有新定位也通知更新。
    public func tick() {
        guard isActive, let sample = currentSample() else { return }
        if sample.quality != lastPublishedQuality {
            notifyUpdate(force: true)
        }
    }

    // MARK: - WorkoutLiveObserver

    public func workoutDidStart(_ configuration: WorkoutConfigurationRequest, at date: Date) {
        guard Self.appliesTo(configuration) else {
            stop()
            return
        }
        isActive = true
        calculator.reset()
        calculator.authorization = provider.authorization
        lastPublishedQuality = nil
        switch provider.authorization {
        case .notDetermined:
            provider.requestAuthorization()
            provider.startUpdates()
        case .authorized:
            provider.startUpdates()
        case .denied:
            break
        }
    }

    public func workoutPhaseDidChange(to phase: WorkoutSessionPhase, at date: Date) {
        guard isActive else { return }
        switch phase {
        case .paused:
            calculator.pause()
            // 暂停时 HealthKit 不再产生指标，需要主动把“已暂停”的速度状态发出去。
            notifyUpdate(force: true)
        case .running:
            if calculator.isPaused {
                calculator.resume()
                notifyUpdate(force: true)
            }
        case .stopped, .ended:
            stop()
        case .notStarted, .prepared:
            break
        }
    }

    public func workoutMetricsWillPublish(_ metrics: WorkoutMetricsSnapshot) -> WorkoutMetricsSnapshot {
        guard let sample = currentSample() else { return metrics }
        lastPublishedQuality = sample.quality
        return metrics.with(speed: sample)
    }

    public func workoutDidEnd() {
        stop()
    }

    // MARK: - Private

    private func stop() {
        if isActive {
            provider.stopUpdates()
        }
        isActive = false
        calculator.reset()
    }

    private func handle(_ fix: LocationFix) {
        guard isActive else { return }
        if calculator.ingest(fix, receivedAt: now()) == .accepted {
            notifyUpdate(force: false)
        }
    }

    private func handleAuthorization(_ status: LocationAuthorization) {
        calculator.authorization = status
        guard isActive else { return }
        if status == .authorized {
            provider.startUpdates()
        }
        notifyUpdate(force: true)
    }

    private func notifyUpdate(force: Bool) {
        let date = now()
        if !force, let lastUpdateAt, date.timeIntervalSince(lastUpdateAt) < minimumUpdateInterval {
            return
        }
        lastUpdateAt = date
        onUpdate?()
    }
}

/// 模拟定位：确定性的骑行速度曲线，含少量无效样本与一个跳点，用于测试、Preview 与演示模式（非真实数据）。
@MainActor
public final class SimulatedLocationFixProvider: LocationFixProvider {
    public let dataOrigin: HealthDataOrigin = .simulated
    public var authorization: LocationAuthorization
    public var fixHandler: ((LocationFix) -> Void)?
    public var authorizationHandler: ((LocationAuthorization) -> Void)?
    /// 用户在授权框中的选择（测试用）。
    public var authorizationResponse: LocationAuthorization = .authorized
    public private(set) var isUpdating = false
    public private(set) var startCount = 0
    public private(set) var stopCount = 0
    private var startedAt: Date?
    private var lastFixAt: Date?
    private var generator = SeededRandomGenerator(seed: 42)

    public init(authorization: LocationAuthorization = .authorized) {
        self.authorization = authorization
    }

    public func requestAuthorization() {
        authorization = authorizationResponse
        authorizationHandler?(authorization)
    }

    public func startUpdates() {
        guard !isUpdating else { return }
        isUpdating = true
        startCount += 1
    }

    public func stopUpdates() {
        guard isUpdating else { return }
        isUpdating = false
        stopCount += 1
        startedAt = nil
        lastFixAt = nil
    }

    /// 推进模拟时钟，每秒最多产生一条定位。
    public func advance(to date: Date) {
        guard isUpdating, authorization == .authorized else { return }
        if startedAt == nil { startedAt = date }
        if let lastFixAt, date.timeIntervalSince(lastFixAt) < 1 { return }
        lastFixAt = date
        let elapsed = date.timeIntervalSince(startedAt ?? date)
        let index = Int(elapsed)
        // 约 22–28 km/h 的起伏；每 37 秒一个无效样本，第 61 秒一个跳点（会被过滤）。
        var speed = 6.9 + 0.9 * sin(elapsed / 40) + generator.value(in: -0.3...0.3)
        if elapsed < 20 { speed *= elapsed / 20 }
        if index % 37 == 36 { speed = -1 }
        if index == 61 { speed = 25 }
        fixHandler?(LocationFix(timestamp: date, speed: speed, speedAccuracy: 0.6, horizontalAccuracy: 6))
    }

    public func emit(_ fix: LocationFix) {
        fixHandler?(fix)
    }
}
