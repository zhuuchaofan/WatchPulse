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
    /// 最近一次结束并保存的运动（仅当 HealthKit 确认保存后才有值）。
    public private(set) var completedWorkout: WorkoutRecord?
    /// 运动记录的保存状态。结束运动 ≠ 保存成功。
    public private(set) var saveStatus: WorkoutSaveStatus = .pending
    /// 最终“已结束 + 保存结果”是否已确认送达 iPhone；没有镜像发送器时为 `nil`。
    public private(set) var finalStateDelivered: Bool?
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
    /// 等待最终状态送达确认的上限。
    @ObservationIgnored public let finalDeliveryTimeout: Duration
    /// v0.2 扩展点（GPS 测速、心率区间提醒）。
    @ObservationIgnored private var observers: [any WorkoutLiveObserver] = []
    /// Watch 上设置的心率区间，随完整状态同步给 iPhone。
    @ObservationIgnored public var heartRateZones: HeartRateZoneSettings?
    /// 开启震动提醒时的目标区间，随完整状态同步给 iPhone。
    @ObservationIgnored public var targetZone: TrainingZone?

    public init(
        driver: any WorkoutSessionDriver,
        sender: (any WorkoutMirroringSender)?,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        heartbeatInterval: TimeInterval = 5,
        reconnectDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10), .seconds(20), .seconds(30)],
        slowRetryInterval: TimeInterval = 60,
        finalDeliveryTimeout: Duration = .seconds(5)
    ) {
        self.driver = driver
        self.sender = sender
        self.now = now
        self.sleep = sleep
        self.heartbeatInterval = heartbeatInterval
        self.reconnectDelays = reconnectDelays
        self.slowRetryInterval = slowRetryInterval
        self.finalDeliveryTimeout = finalDeliveryTimeout
        driver.eventHandler = { [weak self] event in
            self?.handle(event)
        }
    }

    public var dataOrigin: HealthDataOrigin { driver.dataOrigin }

    /// 注册扩展观察者（在开始运动前调用）。
    public func addObserver(_ observer: any WorkoutLiveObserver) {
        observers.append(observer)
    }

    /// 观察者有新数据（例如新的 GPS 速度）时调用：重新补充最新指标并发给 iPhone。
    /// 时间戳与时长保持不变，iPhone 端按“同一时刻的更新”处理。
    public func refreshMetrics() {
        guard phase.isActive, let latestMetrics else { return }
        let refreshed = augment(latestMetrics)
        guard refreshed != latestMetrics else { return }
        self.latestMetrics = refreshed
        send(.metrics(refreshed))
    }

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
        saveStatus = .pending
        finalStateDelivered = nil

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
        // 只有驱动上报 `.mirroringConnected` 后才算已连接；仅有发送器对象不代表镜像已建立。
        isMirroringConnected = false
        phase = .prepared
        // 先通知观察者（例如开始定位），驱动开始后的阶段变化才能被观察到。
        observers.forEach { $0.workoutDidStart(configuration, at: date) }

        do {
            try await driver.start(configuration, at: date)
        } catch {
            observers.forEach { $0.workoutDidEnd() }
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

    /// 结束运动：停止 → 保存（HealthKit 确认）→ 把“已结束 + 保存结果”发给 iPhone 并等待送达确认 → 结束会话。
    ///
    /// 最终状态必须在 `endSession()` 之前送达，因为会话结束后镜像连接随之关闭，之后的发送都会失败。
    /// 送达失败或超时时 `finalStateDelivered == false`；iPhone 会在镜像会话结束时进入“已结束、保存结果未知”。
    public func end() async {
        guard phase.isActive else {
            lastError = .invalidTransition(from: phase, action: "结束")
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let date = now()
        observers.forEach { $0.workoutDidEnd() }
        saveStatus = .saving
        sendStateSync()

        do {
            let record = try await driver.stopAndSave(at: date)
            completedWorkout = record
            saveStatus = .saved(workoutID: record.id)
        } catch {
            // 原因只作诊断信息随状态传给 iPhone；界面显示的是 `errorDescription` 中的通俗说明。
            let reason = Self.map(error).diagnosticDescription
            lastError = .saveFailed(reason: reason)
            saveStatus = .failed(reason: reason)
        }

        cancelReconnect()
        if sender != nil {
            finalStateDelivered = await deliverFinalState()
        }

        // 此后镜像关闭，不再发送任何消息。
        isMirroringConnected = false
        phase = .ended
        driver.endSession()
    }

    /// 关闭“运动已结束”摘要，回到初始状态。
    public func dismissSummary() {
        guard phase == .ended else { return }
        phase = .notStarted
        configuration = nil
        startDate = nil
        latestMetrics = nil
        completedWorkout = nil
        saveStatus = .pending
        finalStateDelivered = nil
        lastError = nil
    }

    /// App 启动或系统要求恢复时调用：恢复崩溃前进行中的运动。
    public func recoverIfNeeded() async {
        guard !phase.isActive, !isBusy else { return }
        isMirroringConnected = false
        do {
            guard let snapshot = try await driver.recoverActiveSession(), snapshot.phase.isActive else {
                return
            }
            sessionID = UUID()
            sequence = 0
            configuration = snapshot.configuration
            phase = snapshot.phase
            startDate = snapshot.startDate
            latestMetrics = snapshot.metrics
            saveStatus = .pending
            completedWorkout = nil
            if let configuration = snapshot.configuration {
                observers.forEach {
                    $0.workoutDidStart(configuration, at: snapshot.startDate ?? now())
                    $0.workoutPhaseDidChange(to: snapshot.phase, at: now())
                }
            }
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
            if phase == .paused, newPhase == .running {
                latestMetrics = latestMetrics?.rebased(to: date)
            }
            phase = newPhase
            observers.forEach { $0.workoutPhaseDidChange(to: newPhase, at: date) }
            send(.phaseChanged(newPhase, at: date))

        case .metrics(let metrics):
            guard phase.isActive else { return }
            if let current = latestMetrics, metrics.timestamp < current.timestamp {
                return
            }
            let augmented = augment(metrics)
            latestMetrics = augmented
            send(.metrics(augmented))

        case .remoteDataReceived(let data):
            handleRemote(data)

        case .mirroringConnected:
            guard sender != nil, !isMirroringConnected else { return }
            isMirroringConnected = true
            cancelReconnect()
            if lastError == .mirroringUnavailable {
                lastError = nil
            }
            // 恢复流程中镜像可能先于状态恢复建立：此时还没有可同步的运动，恢复完成后会再同步。
            if phase.isActive {
                sendStateSync()
            }

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

    /// 发送最终状态（阶段 `.ended` + 保存结果）并等待系统的送达确认，最多 `finalDeliveryTimeout`。
    private func deliverFinalState() async -> Bool {
        guard let sender, isMirroringConnected else { return false }
        sequence += 1
        let envelope = WorkoutMirroringEnvelope(
            sessionID: sessionID,
            sequence: sequence,
            sentAt: now(),
            message: .stateSync(WorkoutStateSnapshot(
                configuration: configuration,
                phase: .ended,
                startDate: startDate,
                metrics: latestMetrics,
                saveStatus: saveStatus,
                heartRateZones: heartRateZones,
                targetZone: targetZone
            ))
        )
        guard let data = try? WorkoutMirroringCodec.encode(envelope) else { return false }

        let gate = ResumeGate()
        let timeout = finalDeliveryTimeout
        return await withCheckedContinuation { continuation in
            let sendTask = Task {
                do {
                    try await sender.sendAndConfirm(data)
                    gate.resume(continuation, with: true)
                } catch {
                    gate.resume(continuation, with: false)
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                sendTask.cancel()
                gate.resume(continuation, with: false)
            }
        }
    }

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
        case .phaseChanged, .metrics, .stateSync, .heartbeat, .commandRejected, .saveResult:
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
            metrics: latestMetrics,
            saveStatus: saveStatus,
            heartRateZones: heartRateZones,
            targetZone: targetZone
        )))
    }

    private func augment(_ metrics: WorkoutMetricsSnapshot) -> WorkoutMetricsSnapshot {
        observers.reduce(metrics) { current, observer in
            let next = observer.workoutMetricsWillPublish(current)
            // 观察者只能补充字段，计时由 HealthKit 决定。
            guard next.timestamp == current.timestamp, next.elapsedTime == current.elapsedTime else { return current }
            return next
        }
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

/// 保证 continuation 只被恢复一次（送达确认与超时竞争）。
@MainActor
private final class ResumeGate {
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Bool, Never>, with value: Bool) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
