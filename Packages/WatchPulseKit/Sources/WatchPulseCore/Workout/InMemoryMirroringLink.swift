import Foundation
import Observation
import WatchPulseShared

/// 内存中的“Watch ↔ iPhone”镜像链路，用于测试与演示模式，可模拟断线、延迟、乱序与丢包。
@MainActor
public final class InMemoryMirroringLink {
    public enum Direction: Sendable {
        case toPhone
        case toWatch
    }

    @MainActor
    public final class Endpoint: WorkoutMirroringSender {
        private unowned let link: InMemoryMirroringLink
        private let direction: Direction

        init(link: InMemoryMirroringLink, direction: Direction) {
            self.link = link
            self.direction = direction
        }

        public func send(_ data: Data) throws {
            try link.transmit(data, direction)
        }

        /// 内存链路同步送达，送达即确认；未连接时抛错。
        public func sendAndConfirm(_ data: Data) async throws {
            try link.transmit(data, direction)
        }
    }

    public private(set) var isConnected = true
    /// 对端是否可达；不可达时 `reconnect()` 失败。
    public var isReachable = true
    /// 为 `false` 时消息进入 `pending`，需调用 `flush()` 才送达（模拟延迟 / 乱序）。
    public var deliversImmediately = true
    public private(set) var pending: [(direction: Direction, data: Data)] = []
    public private(set) var deliveredCount = 0
    public private(set) var droppedCount = 0

    public var onDeliverToPhone: ((Data) -> Void)?
    public var onDeliverToWatch: ((Data) -> Void)?
    /// 链路断开时通知两端。
    public var onDisconnect: ((String?) -> Void)?
    /// 链路恢复时通知 iPhone（真实环境中相当于镜像会话重新建立）。
    public var onReconnect: (() -> Void)?
    /// Watch 结束会话、镜像关闭时通知 iPhone（真实环境中相当于镜像会话进入 `.ended`）。
    public var onSessionEnded: (() -> Void)?
    public private(set) var isSessionClosed = false

    public private(set) lazy var watchEndpoint = Endpoint(link: self, direction: .toPhone)
    public private(set) lazy var phoneEndpoint = Endpoint(link: self, direction: .toWatch)

    public init() {}

    public func disconnect(reason: String?) {
        guard isConnected else { return }
        isConnected = false
        droppedCount += pending.count
        pending.removeAll()
        onDisconnect?(reason)
    }

    /// Watch 结束会话：镜像永久关闭，之后的发送与重连都会失败。
    public func closeSession() {
        guard !isSessionClosed else { return }
        isSessionClosed = true
        isConnected = false
        droppedCount += pending.count
        pending.removeAll()
        onSessionEnded?()
    }

    public func reconnect() throws {
        guard isReachable, !isSessionClosed else { throw WorkoutSessionError.notConnected }
        guard !isConnected else { return }
        isConnected = true
        onReconnect?()
    }

    /// 新运动开始时建立新的镜像会话。
    public func openNewSession() {
        isSessionClosed = false
        isConnected = isReachable
    }

    /// 送达积压的消息；`reversed` 为 `true` 时倒序送达，用于测试乱序。
    public func flush(reversed: Bool = false) {
        let items = reversed ? pending.reversed() : pending
        pending.removeAll()
        for item in items {
            deliver(item.data, item.direction)
        }
    }

    fileprivate func transmit(_ data: Data, _ direction: Direction) throws {
        guard isConnected else {
            droppedCount += 1
            throw WorkoutSessionError.notConnected
        }
        if deliversImmediately {
            deliver(data, direction)
        } else {
            pending.append((direction, data))
        }
    }

    private func deliver(_ data: Data, _ direction: Direction) {
        deliveredCount += 1
        switch direction {
        case .toPhone: onDeliverToPhone?(data)
        case .toWatch: onDeliverToWatch?(data)
        }
    }
}

/// 把模拟 Watch（驱动 + 状态机）、内存链路与 iPhone 仪表盘串起来，用于演示模式与集成测试。
///
/// 所有数据都是模拟的，界面必须显示“模拟数据”标注。
@MainActor
@Observable
public final class SimulatedMirroredWorkout {
    @ObservationIgnored public let link: InMemoryMirroringLink
    @ObservationIgnored public let driver: SimulatedWorkoutSessionDriver
    public let watch: WorkoutSessionController
    public let monitor: LiveWorkoutMonitor
    public private(set) var isOutageActive = false

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    public init(
        monitor: LiveWorkoutMonitor,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        reconnectDelays: [Duration] = [.seconds(2), .seconds(3), .seconds(5), .seconds(8), .seconds(13)]
    ) {
        let link = InMemoryMirroringLink()
        let driver = SimulatedWorkoutSessionDriver()
        self.link = link
        self.driver = driver
        self.monitor = monitor
        self.now = now
        self.sleep = sleep
        watch = WorkoutSessionController(
            driver: driver,
            sender: link.watchEndpoint,
            now: now,
            sleep: sleep,
            reconnectDelays: reconnectDelays
        )
        monitor.attach(sender: link.phoneEndpoint)

        link.onDeliverToPhone = { [weak monitor] data in monitor?.receive(data) }
        link.onDeliverToWatch = { [weak driver] data in driver?.deliverRemoteData(data) }
        link.onDisconnect = { [weak monitor, weak driver] reason in
            monitor?.transportDidDisconnect(reason: reason)
            driver?.simulateMirroringDisconnect(reason: reason)
        }
        link.onReconnect = { [weak monitor] in monitor?.sessionDidStart() }
        link.onSessionEnded = { [weak monitor] in monitor?.remoteSessionEnded() }
        driver.mirroringReconnector = { [weak link] in try link?.reconnect() }
        driver.sessionEndedHandler = { [weak link] in link?.closeSession() }
    }

    /// 在“Watch”上开始一次模拟运动（每次运动都是新的镜像会话）。
    public func start(_ configuration: WorkoutConfigurationRequest) async {
        link.openNewSession()
        monitor.sessionDidStart()
        await watch.start(configuration)
    }

    /// 推进一次模拟时钟：生成指标、发送心跳、检测连接。
    public func tick() {
        driver.advance(to: now())
        watch.tick()
        monitor.evaluateConnection()
    }

    /// 以固定间隔自动 `tick()`，直到 `stopLoop()`。
    public func startLoop(interval: Duration = .seconds(1)) {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self, sleep] in
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                self?.tick()
            }
        }
    }

    public func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// 模拟蓝牙断开：链路不可达，Watch 端重连会失败，直到 `endOutage()`。
    public func beginOutage() {
        isOutageActive = true
        link.isReachable = false
        link.disconnect(reason: "模拟：Apple Watch 与 iPhone 断开")
    }

    /// 结束断线：Watch 端下一次重连会成功。
    public func endOutage() {
        isOutageActive = false
        link.isReachable = true
    }
}
