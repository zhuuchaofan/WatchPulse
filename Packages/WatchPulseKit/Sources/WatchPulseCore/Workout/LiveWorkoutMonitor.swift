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
            case .stale: return "信号弱，等待数据…"
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
    public private(set) var commandError: String?
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

    public func transportDidDisconnect(reason: String?) {
        guard phase != .ended else { return }
        connection = .disconnected(reason: reason)
    }

    /// 由界面定时器调用，检测长时间没有消息的情况。
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
        guard phase.isActive else {
            commandError = "当前没有进行中的运动"
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
            if let last = heartRateHistory.last, last.date >= metrics.timestamp {
                return
            }
            heartRateHistory.append(HeartRatePoint(date: metrics.timestamp, beatsPerMinute: heartRate))
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
