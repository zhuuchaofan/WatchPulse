import Foundation
import Observation
import WatchPulseShared

/// Watch 端运动状态机：开始 / 暂停 / 继续 / 结束、向 iPhone 同步、处理 iPhone 命令、断线重连、崩溃恢复。
///
/// 真实运动由 `WorkoutSessionDriver` 执行（HealthKit 或模拟实现），镜像数据经 `WorkoutMirroringSender` 发送。
/// 所有状态变化都在主线程同步完成，便于单元测试。
@MainActor
@Observable
public final class WorkoutSessionController {
    public private(set) var phase: WorkoutSessionPhase = .notStarted
    public private(set) var configuration: WorkoutConfigurationRequest?
    public private(set) var startDate: Date?
    public private(set) var latestMetrics: WorkoutMetricsSnapshot?
    /// 与 iPhone 的镜像连接是否可用。
    public private(set) var isMirroringConnected = false
    /// 是否正在后台重连 iPhone。
    public private(set) var isReconnecting = false
    public private(set) var lastError: WorkoutSessionError?
    /// 最近一次结束并保存的运动。
    public private(set) var completedWorkout: WorkoutRecord?
    /// 正在开始或结束运动。
    public private(set) var isBusy = false
    public private(set) var sentMessageCount = 0
    public private(set) var invalidMessageCount = 0

    @ObservationIgnored private let driver: any WorkoutSessionDriver
    @ObservationIgnored private let sender: (any WorkoutMirroringSender)?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored public let heartbeatInterval: TimeInterval
    @ObservationIgnored public let reconnectDelays: [Duration]
    /// 一轮重连全部失败后，再次尝试的间隔（由 `tick()` 触发）。
    @ObservationIgnored public let slowRetryInterval: TimeInterval
    @ObservationIgnored private var reconnectRoundEndedAt: Date?
    @ObservationIgnored public private(set) var sessionID = UUID()
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var lastSentAt: Date?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var endTask: Task<Void, Never>?

    public init(
        driver: any WorkoutSessionDriver,
        sender: (any WorkoutMirroringSender)?,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        heartbeatInterval: TimeInterval = 5,
        reconnectDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10), .seconds(20), .seconds(30)],
        slowRetryInterval: TimeInterval = 60
    ) {
        self.driver = driver
        self.sender = sender
        self.now = now
        self.sleep = sleep
        self.heartbeatInterval = heartbeatInterval
        self.reconnectDelays = reconnectDelays
        self.slowRetryInterval = slowRetryInterval
        driver.eventHandler = { [weak self] event in
            self?.handle(event)
        }
    }

    public var dataOrigin: HealthDataOrigin { driver.dataOrigin }

    /// 当前运动时长（运动进行中时实时推算）。
    public func elapsedTime(at date: Date) -> TimeInterval {
        latestMetrics?.elapsedTime(at: date, isRunning: phase == .running) ?? 0
    }

    // MARK: - 用户操作

    public func start(_ configuration: WorkoutConfigurationRequest) async {
        guard !isBusy, !phase.isActive else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        completedWorkout = nil

        do {
            try await driver.requestAuthorization()
        } catch {
            lastError = Self.map(error)
            return
        }

        let date = now()
        sessionID = UUID()
        sequence = 0
        lastSentAt = nil
        self.configuration = configuration
        startDate = date
        latestMetrics = WorkoutMetricsSnapshot(timestamp: date, elapsedTime: 0)
        isMirroringConnected = sender != nil
        phase = .prepared

        do {
            try await driver.start(configuration, at: date)
        } catch {
            cancelReconnect()
            phase = .notStarted
            self.configuration = nil
            startDate = nil
            latestMetrics = nil
            isMirroringConnected = false
            lastError = Self.map(error)
            return
        }

        if phase == .prepared {
            phase = .running
        }
        sendStateSync()
        if sender != nil, !isMirroringConnected {
            scheduleReconnect()
        }
    }

    public func pause() {
        guard phase == .running else {
            lastError = .invalidTransition(from: phase, action: "暂停")
            return
        }
        driver.pause(at: now())
    }

    public func resume() {
        guard phase == .paused else {
            lastError = .invalidTransition(from: phase, action: "继续")
            return
        }
        driver.resume(at: now())
    }

    public func end() async {
        guard phase.isActive else {
            lastError = .invalidTransition(from: phase, action: "结束")
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let date = now()
        // 先通知 iPhone：结束后镜像连接会随会话关闭。
        send(.stateSync(WorkoutStateSnapshot(
            configuration: configuration,
            phase: .ended,
            startDate: startDate,
            metrics: latestMetrics
        )))

        do {
            completedWorkout = try await driver.end(at: date)
        } catch {
            // 会话已结束但保存失败：保留错误给用户看。
            lastError = .saveFailed(reason: Self.map(error).localizedDescription)
        }
        phase = .ended
        cancelReconnect()
        isMirroringConnected = false
    }

    /// 关闭“运动已结束”摘要，回到初始状态。
    public func dismissSummary() {
        guard phase == .ended else { return }
        phase = .notStarted
        configuration = nil
        startDate = nil
        latestMetrics = nil
        completedWorkout = nil
        lastError = nil
    }

    /// App 启动或系统要求恢复时调用：恢复崩溃前进行中的运动。
    public func recoverIfNeeded() async {
        guard !phase.isActive, !isBusy else { return }
        isMirroringConnected = sender != nil
        do {
            guard let snapshot = try await driver.recoverActiveSession(), snapshot.phase.isActive else {
                isMirroringConnected = false
                return
            }
            sessionID = UUID()
            sequence = 0
            configuration = snapshot.configuration
            phase = snapshot.phase
            startDate = snapshot.startDate
            latestMetrics = snapshot.metrics
            sendStateSync()
            if sender != nil, !isMirroringConnected {
                scheduleReconnect()
            }
        } catch {
            isMirroringConnected = false
            lastError = Self.map(error)
        }
    }

    /// 由界面定时器每秒调用：在没有其他消息时发送心跳；镜像长时间不可用时定期再次重连。
    public func tick() {
        guard phase.isActive else { return }
        let date = now()
        guard isMirroringConnected else {
            if sender != nil, reconnectTask == nil,
               date.timeIntervalSince(reconnectRoundEndedAt ?? .distantPast) >= slowRetryInterval {
                scheduleReconnect()
            }
            return
        }
        if let lastSentAt, date.timeIntervalSince(lastSentAt) < heartbeatInterval {
            return
        }
        send(.heartbeat(at: date))
    }

    // MARK: - 驱动事件

    public func handle(_ event: WorkoutDriverEvent) {
        switch event {
        case .phaseChanged(let newPhase, let date):
            guard newPhase != phase, newPhase != .notStarted else { return }
            phase = newPhase
            send(.phaseChanged(newPhase, at: date))

        case .metrics(let metrics):
            guard phase.isActive else { return }
            if let current = latestMetrics, metrics.timestamp < current.timestamp {
                return
            }
            latestMetrics = metrics
            send(.metrics(metrics))

        case .remoteDataReceived(let data):
            handleRemote(data)

        case .mirroringDisconnected:
            markDisconnected()

        case .failed(let reason):
            lastError = .sessionFailed(reason: reason)
        }
    }

    // MARK: - 测试辅助

    /// 等待后台重连 / 远程结束等任务完成。
    public func waitForPendingWork() async {
        await reconnectTask?.value
        await endTask?.value
    }

    // MARK: - Private

    private func handleRemote(_ data: Data) {
        guard let envelope = try? WorkoutMirroringCodec.decode(data) else {
            invalidMessageCount += 1
            return
        }
        if !isMirroringConnected, phase.isActive {
            // 能收到 iPhone 的数据说明连接已恢复。
            isMirroringConnected = true
            cancelReconnect()
            sendStateSync()
        }
        switch envelope.message {
        case .command(let command):
            apply(command)
        case .requestStateSync:
            sendStateSync()
        case .phaseChanged, .metrics, .stateSync, .heartbeat, .commandRejected:
            break
        }
    }

    private func apply(_ command: WorkoutRemoteCommand) {
        switch command {
        case .pause:
            guard phase == .running else { return reject(command) }
            driver.pause(at: now())
        case .resume:
            guard phase == .paused else { return reject(command) }
            driver.resume(at: now())
        case .end:
            guard phase.isActive, !isBusy else { return reject(command) }
            endTask = Task { [weak self] in
                await self?.end()
            }
        }
    }

    private func reject(_ command: WorkoutRemoteCommand) {
        send(.commandRejected(command, reason: "运动\(phase.title)"))
    }

    private func sendStateSync() {
        send(.stateSync(WorkoutStateSnapshot(
            configuration: configuration,
            phase: phase,
            startDate: startDate,
            metrics: latestMetrics
        )))
    }

    private func send(_ message: WorkoutMirroringMessage) {
        guard let sender, isMirroringConnected else { return }
        sequence += 1
        let envelope = WorkoutMirroringEnvelope(sessionID: sessionID, sequence: sequence, sentAt: now(), message: message)
        do {
            try sender.send(WorkoutMirroringCodec.encode(envelope))
            lastSentAt = envelope.sentAt
            sentMessageCount += 1
        } catch {
            markDisconnected()
        }
    }

    private func markDisconnected() {
        isMirroringConnected = false
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard sender != nil, phase.isActive, reconnectTask == nil else { return }
        isReconnecting = true
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    private func runReconnectLoop() async {
        defer {
            // 被取消的旧任务不能清掉之后新建的重连任务。
            if !Task.isCancelled {
                reconnectTask = nil
                isReconnecting = false
            }
        }
        for delay in reconnectDelays {
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, phase.isActive else { return }
            if isMirroringConnected { return }
            reconnectRoundEndedAt = now()
            do {
                try await driver.reconnectMirroring()
                isMirroringConnected = true
                if lastError == .mirroringUnavailable {
                    lastError = nil
                }
                sendStateSync()
                return
            } catch {
                continue
            }
        }
        lastError = .mirroringUnavailable
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
    }

    static func map(_ error: Error) -> WorkoutSessionError {
        (error as? WorkoutSessionError) ?? .sessionFailed(reason: error.localizedDescription)
    }
}
