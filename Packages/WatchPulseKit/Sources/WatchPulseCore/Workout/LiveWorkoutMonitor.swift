import Foundation
import Observation
import WatchPulseShared

/// iPhone 端实时运动仪表盘的数据源：接收 Watch 镜像过来的消息，维护连接状态，发送控制命令。
///
/// 只处理 `Data`，与 HealthKit 解耦：真实环境由 `HKWorkoutSession` 的镜像回调喂数据，
/// 测试与演示模式由 `InMemoryMirroringLink` 喂数据。
@MainActor
@Observable
public final class LiveWorkoutMonitor {
    public enum ConnectionState: Hashable, Sendable {
        /// 还没有收到过 Watch 的运动。
        case waiting
        case connected
        /// 超过 `staleInterval` 没有收到任何消息（可能信号弱）。
        case stale
        /// 镜像连接明确断开。
        case disconnected(reason: String?)

        public var title: String {
            switch self {
            case .waiting: return "等待 Apple Watch"
            case .connected: return "已连接"
            case .stale: return "数据暂时中断，等待中…"
            case .disconnected: return "连接已断开，正在等待恢复"
            }
        }
    }

    public private(set) var connection: ConnectionState = .waiting
    public private(set) var configuration: WorkoutConfigurationRequest?
    public private(set) var phase: WorkoutSessionPhase = .notStarted
    public private(set) var startDate: Date?
    public private(set) var latestMetrics: WorkoutMetricsSnapshot?
    /// 本次运动收到的心率曲线（有上限）。
    public private(set) var heartRateHistory: [HeartRatePoint] = []
    public private(set) var lastMessageAt: Date?
    /// 已发送、等待 Watch 确认的命令。
    public private(set) var pendingCommand: WorkoutRemoteCommand?
    /// Watch 报告的保存状态。只有 `.saved` 才能向用户显示“已保存”。
    public private(set) var saveStatus: WorkoutSaveStatus = .pending
    public private(set) var commandError: String?
    /// Watch 上设置的心率区间（来自完整状态同步）；未设置为 `nil`。
    public private(set) var heartRateZones: HeartRateZoneSettings?
    /// Watch 上开启提醒时的目标区间。
    public private(set) var targetZone: TrainingZone?
    public private(set) var droppedMessageCount = 0
    public private(set) var invalidMessageCount = 0

    public let dataOrigin: HealthDataOrigin

    @ObservationIgnored private var sender: (any WorkoutMirroringSender)?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var lastSequence: UInt64 = 0
    @ObservationIgnored private var outgoingSequence: UInt64 = 0
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored public let staleInterval: TimeInterval
    @ObservationIgnored public let historyLimit: Int
    @ObservationIgnored private var watchdogTask: Task<Void, Never>?

    public init(
        dataOrigin: HealthDataOrigin,
        now: @escaping () -> Date = { Date() },
        staleInterval: TimeInterval = 12,
        historyLimit: Int = 3_600
    ) {
        self.dataOrigin = dataOrigin
        self.now = now
        self.staleInterval = staleInterval
        self.historyLimit = historyLimit
    }

    /// 是否有正在进行或刚结束的运动可展示。
    public var hasWorkout: Bool { phase != .notStarted }

    public var isConnected: Bool { connection == .connected }

    /// 只有运动进行中或暂停时才能控制；`.stopped`（正在结束 / 保存）时不提供控制。
    public var canSendCommands: Bool { phase == .running || phase == .paused }

    public func elapsedTime(at date: Date) -> TimeInterval {
        latestMetrics?.elapsedTime(at: date, isRunning: phase == .running) ?? 0
    }

    // MARK: - 传输层回调

    public func attach(sender: any WorkoutMirroringSender) {
        self.sender = sender
    }

    /// 镜像会话建立（首次或重连）。请求一次完整状态。
    public func sessionDidStart() {
        connection = .connected
        lastMessageAt = now()
        sendToWatch(.requestStateSync)
    }

    public func receive(_ data: Data) {
        guard let envelope = try? WorkoutMirroringCodec.decode(data) else {
            invalidMessageCount += 1
            return
        }
        if envelope.sessionID != sessionID {
            // Watch 端开始了新的会话（新运动或崩溃恢复），重置序号。
            sessionID = envelope.sessionID
            lastSequence = 0
        }
        guard envelope.sequence > lastSequence else {
            droppedMessageCount += 1
            return
        }
        lastSequence = envelope.sequence

        let wasConnected = connection == .connected
        lastMessageAt = now()
        connection = .connected
        apply(envelope.message)

        if !wasConnected, phase.isActive {
            if case .stateSync = envelope.message {} else {
                // 断线期间可能错过了阶段变化，请求完整状态。
                sendToWatch(.requestStateSync)
            }
        }
    }

    /// 镜像会话已结束（系统回调）。即使没收到最终消息，也明确进入“已结束”；
    /// 保存状态保持原样——没收到 `.saved` 就不会显示已保存。
    public func remoteSessionEnded() {
        guard phase != .notStarted, phase != .ended else { return }
        updatePhase(.ended)
        pendingCommand = nil
    }

    public func transportDidDisconnect(reason: String?) {
        guard phase != .ended else { return }
        connection = .disconnected(reason: reason)
    }

    /// 启动连接看门狗：定期调用 `evaluateConnection()`。在 App 层启动，不依赖任何页面是否打开。
    /// 重复调用不会启动多个。
    public func startConnectionWatchdog(
        interval: Duration = .seconds(1),
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                self?.evaluateConnection()
            }
        }
    }

    public func stopConnectionWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    public var isConnectionWatchdogRunning: Bool { watchdogTask != nil }

    /// 检测长时间没有消息的情况（由看门狗定期调用；App 回到前台时也应立即调用一次）。
    public func evaluateConnection() {
        guard connection == .connected, phase.isActive, let lastMessageAt else { return }
        if now().timeIntervalSince(lastMessageAt) > staleInterval {
            connection = .stale
        }
    }

    // MARK: - 命令

    @discardableResult
    public func send(_ command: WorkoutRemoteCommand) -> Bool {
        commandError = nil
        guard canSendCommands else {
            commandError = phase == .stopped ? "Apple Watch 正在结束运动" : "当前没有进行中的运动"
            return false
        }
        switch connection {
        case .connected, .stale:
            break
        case .waiting, .disconnected:
            commandError = "未连接 Apple Watch，无法\(command.title)"
            return false
        }
        // 先记录等待中的命令：回执可能在发送调用返回前就到达。
        let previous = pendingCommand
        pendingCommand = command
        guard sendToWatch(.command(command)) else {
            pendingCommand = previous
            commandError = "发送失败，无法\(command.title)"
            return false
        }
        return true
    }

    /// 用户关闭已结束运动的摘要。
    public func reset() {
        connection = .waiting
        configuration = nil
        phase = .notStarted
        startDate = nil
        latestMetrics = nil
        heartRateHistory = []
        pendingCommand = nil
        commandError = nil
        saveStatus = .pending
        heartRateZones = nil
        targetZone = nil
    }

    // MARK: - Private

    private func apply(_ message: WorkoutMirroringMessage) {
        switch message {
        case .stateSync(let snapshot):
            if snapshot.startDate != startDate {
                heartRateHistory = []
                latestMetrics = nil
            }
            configuration = snapshot.configuration
            startDate = snapshot.startDate
            saveStatus = snapshot.saveStatus
            heartRateZones = snapshot.heartRateZones
            targetZone = snapshot.targetZone
            updatePhase(snapshot.phase)
            if let metrics = snapshot.metrics {
                applyMetrics(metrics)
            }
        case .phaseChanged(let newPhase, let date):
            if phase == .paused, newPhase == .running {
                latestMetrics = latestMetrics?.rebased(to: date)
            }
            updatePhase(newPhase)
        case .metrics(let metrics):
            applyMetrics(metrics)
        case .saveResult(let status):
            saveStatus = status
        case .commandRejected(let command, let reason):
            pendingCommand = nil
            commandError = "Apple Watch 无法\(command.title)：\(reason)"
        case .heartbeat, .command, .requestStateSync:
            break
        }
    }

    private func updatePhase(_ newPhase: WorkoutSessionPhase) {
        phase = newPhase
        switch (pendingCommand, newPhase) {
        case (.pause?, .paused), (.resume?, .running), (.end?, .ended), (.end?, .stopped):
            pendingCommand = nil
        default:
            if !newPhase.isActive {
                pendingCommand = nil
            }
        }
    }

    private func applyMetrics(_ metrics: WorkoutMetricsSnapshot) {
        if let current = latestMetrics, metrics.timestamp < current.timestamp {
            return
        }
        latestMetrics = metrics
        if let heartRate = metrics.heartRateBPM {
            // 以样本自身的测量时间为准：能量、距离更新时同一个心率样本会被重复携带，不能再画成新点。
            let sampleDate = min(metrics.heartRateDate ?? metrics.timestamp, metrics.timestamp)
            if let last = heartRateHistory.last, last.date >= sampleDate {
                return
            }
            heartRateHistory.append(HeartRatePoint(date: sampleDate, beatsPerMinute: heartRate))
            if heartRateHistory.count > historyLimit {
                heartRateHistory.removeFirst(heartRateHistory.count - historyLimit)
            }
        }
    }

    @discardableResult
    private func sendToWatch(_ message: WorkoutMirroringMessage) -> Bool {
        guard let sender else { return false }
        outgoingSequence += 1
        let envelope = WorkoutMirroringEnvelope(
            sessionID: sessionID ?? UUID(),
            sequence: outgoingSequence,
            sentAt: now(),
            message: message
        )
        do {
            try sender.send(WorkoutMirroringCodec.encode(envelope))
            return true
        } catch {
            if phase.isActive {
                connection = .disconnected(reason: nil)
            }
            return false
        }
    }
}
