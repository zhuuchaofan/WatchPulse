import Foundation
import XCTest
@testable import WatchPulseCore
import WatchPulseShared

/// 可控时钟。
@MainActor
final class TestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) {
        date = date.addingTimeInterval(seconds)
    }
}

/// 记录发出的消息，可模拟发送失败。
@MainActor
final class RecordingSender: WorkoutMirroringSender {
    var sent: [WorkoutMirroringEnvelope] = []
    var isConnected = true

    func send(_ data: Data) throws {
        guard isConnected else { throw WorkoutSessionError.notConnected }
        sent.append(try WorkoutMirroringCodec.decode(data))
    }

    func sendAndConfirm(_ data: Data) async throws {
        try send(data)
    }

    var messages: [WorkoutMirroringMessage] { sent.map(\.message) }
}

private let running = WorkoutConfigurationRequest(activity: .running, location: .outdoor)

// MARK: - Watch 端状态机

@MainActor
final class WorkoutSessionControllerTests: XCTestCase {
    private var clock: TestClock!
    private var driver: SimulatedWorkoutSessionDriver!
    private var sender: RecordingSender!
    private var controller: WorkoutSessionController!

    override func setUp() async throws {
        clock = TestClock()
        driver = SimulatedWorkoutSessionDriver()
        sender = RecordingSender()
        let clock = clock!
        controller = WorkoutSessionController(
            driver: driver,
            sender: sender,
            now: { clock.date },
            sleep: { _ in await Task.yield() },
            heartbeatInterval: 5,
            reconnectDelays: [.seconds(1), .seconds(1), .seconds(1)]
        )
    }

    private func command(_ command: WorkoutRemoteCommand) throws -> Data {
        try WorkoutMirroringCodec.encode(WorkoutMirroringEnvelope(sessionID: controller.sessionID, sequence: 1, sentAt: clock.date, message: .command(command)))
    }

    func testStartRunsWorkoutAndSyncsState() async {
        await controller.start(running)

        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(controller.configuration, running)
        XCTAssertEqual(controller.startDate, clock.date)
        XCTAssertTrue(controller.isMirroringConnected)
        XCTAssertEqual(controller.dataOrigin, .simulated)
        guard case .stateSync(let snapshot)? = sender.messages.last else {
            return XCTFail("expected stateSync, got \(sender.messages)")
        }
        XCTAssertEqual(snapshot.phase, .running)
        XCTAssertEqual(snapshot.configuration, running)
        // 序号严格递增。
        XCTAssertEqual(sender.sent.map(\.sequence), Array(1...UInt64(sender.sent.count)))
    }

    func testMetricsAreForwardedAndStaleMetricsIgnored() async {
        await controller.start(running)
        clock.advance(10)
        driver.advance(to: clock.date)

        XCTAssertEqual(controller.latestMetrics?.elapsedTime, 10)
        XCTAssertNotNil(controller.latestMetrics?.heartRateBPM)
        guard case .metrics(let metrics)? = sender.messages.last else { return XCTFail() }
        XCTAssertEqual(metrics.elapsedTime, 10)

        let count = sender.sent.count
        controller.handle(.metrics(WorkoutMetricsSnapshot(timestamp: clock.date.addingTimeInterval(-5), elapsedTime: 5)))
        XCTAssertEqual(controller.latestMetrics?.elapsedTime, 10)
        XCTAssertEqual(sender.sent.count, count)
    }

    func testPauseResumeAndInvalidTransitions() async {
        controller.pause()
        XCTAssertEqual(controller.lastError, .invalidTransition(from: .notStarted, action: "暂停"))

        await controller.start(running)
        controller.resume()
        XCTAssertEqual(controller.lastError, .invalidTransition(from: .running, action: "继续"))

        controller.pause()
        XCTAssertEqual(controller.phase, .paused)
        controller.resume()
        XCTAssertEqual(controller.phase, .running)
        XCTAssertTrue(sender.messages.contains(.phaseChanged(.paused, at: clock.date)))
    }

    func testEndSavesRecordAndNotifiesPhone() async {
        await controller.start(running)
        clock.advance(60)
        driver.advance(to: clock.date)
        clock.advance(30)
        await controller.end()

        XCTAssertEqual(controller.phase, .ended)
        let record = controller.completedWorkout
        XCTAssertEqual(record?.activity, .running)
        XCTAssertEqual(record?.duration, 90)
        XCTAssertEqual(record?.sourceName, SimulatedWorkoutSessionDriver.sourceName)
        XCTAssertNotNil(record?.distanceMeters)
        XCTAssertFalse(controller.isMirroringConnected)
        XCTAssertTrue(sender.messages.contains { message in
            if case .stateSync(let snapshot) = message { return snapshot.phase == .ended }
            return false
        })

        controller.dismissSummary()
        XCTAssertEqual(controller.phase, .notStarted)
        XCTAssertNil(controller.completedWorkout)
    }

    func testSaveFailureStillEndsWorkout() async {
        driver.endError = .saveFailed(reason: "disk")
        await controller.start(running)
        await controller.end()
        XCTAssertEqual(controller.phase, .ended)
        XCTAssertNil(controller.completedWorkout)
        guard case .saveFailed? = controller.lastError else { return XCTFail("\(String(describing: controller.lastError))") }
    }

    func testAuthorizationAndStartFailures() async {
        driver.authorizationError = .authorizationFailed(reason: "denied")
        await controller.start(running)
        XCTAssertEqual(controller.phase, .notStarted)
        XCTAssertEqual(controller.lastError, .authorizationFailed(reason: "denied"))

        driver.authorizationError = nil
        driver.startError = .sessionStartFailed(reason: "busy")
        await controller.start(running)
        XCTAssertEqual(controller.phase, .notStarted)
        XCTAssertNil(controller.configuration)
        XCTAssertEqual(controller.lastError, .sessionStartFailed(reason: "busy"))
        XCTAssertTrue(sender.sent.isEmpty)
    }

    func testRemoteCommandsAreAppliedOrRejected() async throws {
        await controller.start(running)

        driver.deliverRemoteData(try command(.resume))
        XCTAssertEqual(sender.messages.last, .commandRejected(.resume, reason: "运动进行中"))

        driver.deliverRemoteData(try command(.pause))
        XCTAssertEqual(controller.phase, .paused)

        driver.deliverRemoteData(try command(.resume))
        XCTAssertEqual(controller.phase, .running)

        driver.deliverRemoteData(try command(.end))
        await controller.waitForPendingWork()
        XCTAssertEqual(controller.phase, .ended)
        XCTAssertNotNil(controller.completedWorkout)
    }

    func testRequestStateSyncAndInvalidRemoteData() async throws {
        await controller.start(running)
        let count = sender.sent.count

        driver.deliverRemoteData(Data("garbage".utf8))
        XCTAssertEqual(controller.invalidMessageCount, 1)
        XCTAssertEqual(sender.sent.count, count)

        driver.deliverRemoteData(try WorkoutMirroringCodec.encode(WorkoutMirroringEnvelope(
            sessionID: controller.sessionID, sequence: 2, sentAt: clock.date, message: .requestStateSync
        )))
        guard case .stateSync? = sender.messages.last else { return XCTFail() }
    }

    func testHeartbeatOnlyWhenIdle() async {
        await controller.start(running)
        let count = sender.sent.count

        clock.advance(2)
        controller.tick()
        XCTAssertEqual(sender.sent.count, count)

        clock.advance(4)
        controller.tick()
        XCTAssertEqual(sender.messages.last, .heartbeat(at: clock.date))
    }

    func testDisconnectTriggersReconnectAndResync() async {
        await controller.start(running)
        sender.isConnected = false
        clock.advance(1)
        driver.advance(to: clock.date) // 发送失败 → 断开 → 开始重连
        XCTAssertFalse(controller.isMirroringConnected)
        XCTAssertTrue(controller.isReconnecting)

        sender.isConnected = true
        await controller.waitForPendingWork()

        XCTAssertTrue(controller.isMirroringConnected)
        XCTAssertFalse(controller.isReconnecting)
        XCTAssertEqual(driver.reconnectAttempts, 1)
        guard case .stateSync(let snapshot)? = sender.messages.last else { return XCTFail() }
        XCTAssertEqual(snapshot.metrics?.elapsedTime, 1)
    }

    func testReconnectExhaustionKeepsWorkoutRunningLocally() async {
        driver.mirroringReconnector = { throw WorkoutSessionError.notConnected }
        driver.failMirroringOnStart = true
        await controller.start(running)
        await controller.waitForPendingWork()

        XCTAssertEqual(controller.phase, .running)
        XCTAssertFalse(controller.isMirroringConnected)
        XCTAssertEqual(controller.lastError, .mirroringUnavailable)
        XCTAssertEqual(driver.reconnectAttempts, controller.reconnectDelays.count)

        // 运动仍可在 Watch 上正常结束并保存。
        await controller.end()
        XCTAssertNotNil(controller.completedWorkout)
    }

    func testRecoveryRestoresActiveWorkout() async {
        let start = clock.date.addingTimeInterval(-600)
        driver.recoverableSnapshot = WorkoutStateSnapshot(
            configuration: running,
            phase: .running,
            startDate: start,
            metrics: WorkoutMetricsSnapshot(timestamp: clock.date.addingTimeInterval(-5), elapsedTime: 595, heartRateBPM: 150)
        )

        await controller.recoverIfNeeded()

        XCTAssertEqual(controller.phase, .running)
        XCTAssertEqual(controller.startDate, start)
        // 恢复过程中镜像先于状态恢复建立时，不能先发一条“未开始”的状态。
        XCTAssertFalse(sender.messages.contains { message in
            if case .stateSync(let snapshot) = message { return !snapshot.phase.isActive }
            return false
        }, "\(sender.messages)")
        XCTAssertEqual(Set(sender.sent.map(\.sessionID)), [controller.sessionID])
        XCTAssertEqual(controller.elapsedTime(at: clock.date), 600)
        guard case .stateSync(let snapshot)? = sender.messages.last else { return XCTFail() }
        XCTAssertEqual(snapshot.startDate, start)

        // 没有可恢复的会话时什么也不做。
        let other = WorkoutSessionController(driver: SimulatedWorkoutSessionDriver(), sender: nil)
        await other.recoverIfNeeded()
        XCTAssertEqual(other.phase, .notStarted)
        XCTAssertNil(other.lastError)
    }

    func testWorksWithoutMirroringSender() async {
        let standalone = WorkoutSessionController(driver: driver, sender: nil)
        await standalone.start(running)
        XCTAssertEqual(standalone.phase, .running)
        XCTAssertFalse(standalone.isMirroringConnected)
        XCTAssertFalse(standalone.isReconnecting)
        await standalone.end()
        XCTAssertEqual(standalone.phase, .ended)
    }
}

// MARK: - iPhone 端仪表盘

@MainActor
final class LiveWorkoutMonitorTests: XCTestCase {
    private var clock: TestClock!
    private var monitor: LiveWorkoutMonitor!
    private var sender: RecordingSender!
    private let watchSession = UUID()

    override func setUp() async throws {
        clock = TestClock()
        sender = RecordingSender()
        let clock = clock!
        monitor = LiveWorkoutMonitor(dataOrigin: .healthKit, now: { clock.date }, staleInterval: 10, historyLimit: 100)
        monitor.attach(sender: sender)
    }

    private func data(_ message: WorkoutMirroringMessage, sequence: UInt64, session: UUID? = nil) throws -> Data {
        try WorkoutMirroringCodec.encode(WorkoutMirroringEnvelope(
            sessionID: session ?? watchSession, sequence: sequence, sentAt: clock.date, message: message
        ))
    }

    private func metrics(_ elapsed: TimeInterval, heartRate: Double? = 120) -> WorkoutMetricsSnapshot {
        WorkoutMetricsSnapshot(timestamp: clock.date.addingTimeInterval(elapsed), elapsedTime: elapsed, heartRateBPM: heartRate)
    }

    private func sync(_ phase: WorkoutSessionPhase, start: Date? = nil) -> WorkoutMirroringMessage {
        .stateSync(WorkoutStateSnapshot(configuration: running, phase: phase, startDate: start ?? clock.date, metrics: nil))
    }

    func testInitialState() async {
        XCTAssertEqual(monitor.connection, .waiting)
        XCTAssertFalse(monitor.hasWorkout)
        XCTAssertEqual(monitor.elapsedTime(at: clock.date), 0)
    }

    func testSessionStartRequestsStateSync() async {
        monitor.sessionDidStart()
        XCTAssertEqual(monitor.connection, .connected)
        XCTAssertEqual(sender.messages, [.requestStateSync])
    }

    func testAppliesStateAndMetrics() async throws {
        monitor.receive(try data(sync(.running), sequence: 1))
        monitor.receive(try data(.metrics(metrics(5)), sequence: 2))
        monitor.receive(try data(.metrics(metrics(10, heartRate: 130)), sequence: 3))

        XCTAssertEqual(monitor.phase, .running)
        XCTAssertEqual(monitor.configuration, running)
        XCTAssertEqual(monitor.latestMetrics?.elapsedTime, 10)
        XCTAssertEqual(monitor.heartRateHistory.map(\.beatsPerMinute), [120, 130])
        XCTAssertEqual(monitor.connection, .connected)
    }

    func testFirstNonSyncMessageRequestsFullState() async throws {
        monitor.receive(try data(.metrics(metrics(5)), sequence: 1))
        XCTAssertTrue(sender.messages.isEmpty, "阶段未知时不请求")
        monitor.receive(try data(.phaseChanged(.running, at: clock.date), sequence: 2))
        monitor.transportDidDisconnect(reason: "bt")
        monitor.receive(try data(.metrics(metrics(6)), sequence: 3))
        XCTAssertEqual(sender.messages, [.requestStateSync])
    }

    func testDropsDuplicateAndOutOfOrderMessages() async throws {
        monitor.receive(try data(sync(.running), sequence: 1))
        monitor.receive(try data(.metrics(metrics(10)), sequence: 3))
        monitor.receive(try data(.metrics(metrics(5)), sequence: 2))  // 乱序：丢弃
        monitor.receive(try data(.metrics(metrics(10)), sequence: 3))  // 重复：丢弃
        XCTAssertEqual(monitor.latestMetrics?.elapsedTime, 10)
        XCTAssertEqual(monitor.droppedMessageCount, 2)

        monitor.receive(Data("{}".utf8))
        XCTAssertEqual(monitor.invalidMessageCount, 1)
    }

    func testNewWatchSessionResetsSequenceAndHistory() async throws {
        monitor.receive(try data(sync(.running), sequence: 1))
        monitor.receive(try data(.metrics(metrics(5)), sequence: 50))
        XCTAssertEqual(monitor.heartRateHistory.count, 1)

        // 新的运动：会话 ID 不同、开始时间不同。
        let newStart = clock.date.addingTimeInterval(3_600)
        monitor.receive(try data(sync(.running, start: newStart), sequence: 1, session: UUID()))
        XCTAssertEqual(monitor.startDate, newStart)
        XCTAssertTrue(monitor.heartRateHistory.isEmpty)
        XCTAssertNil(monitor.latestMetrics)
    }

    func testRecoveredSessionWithSameStartKeepsHistory() async throws {
        let start = clock.date
        monitor.receive(try data(sync(.running, start: start), sequence: 1))
        monitor.receive(try data(.metrics(metrics(5)), sequence: 2))
        // Watch App 崩溃恢复：新会话 ID，但是同一次运动。
        monitor.receive(try data(sync(.running, start: start), sequence: 1, session: UUID()))
        XCTAssertEqual(monitor.heartRateHistory.count, 1)
    }

    func testStaleAndDisconnectedStates() async throws {
        monitor.receive(try data(sync(.running), sequence: 1))
        clock.advance(5)
        monitor.evaluateConnection()
        XCTAssertEqual(monitor.connection, .connected)

        clock.advance(6)
        monitor.evaluateConnection()
        XCTAssertEqual(monitor.connection, .stale)

        monitor.receive(try data(.heartbeat(at: clock.date), sequence: 2))
        XCTAssertEqual(monitor.connection, .connected)

        monitor.transportDidDisconnect(reason: "bt")
        XCTAssertEqual(monitor.connection, .disconnected(reason: "bt"))
        XCTAssertFalse(monitor.send(.pause))
        XCTAssertEqual(monitor.commandError, "未连接 Apple Watch，无法暂停")
    }

    func testCommandLifecycle() async throws {
        XCTAssertFalse(monitor.send(.pause))
        XCTAssertEqual(monitor.commandError, "当前没有进行中的运动")

        monitor.receive(try data(sync(.running), sequence: 1))
        XCTAssertTrue(monitor.send(.pause))
        XCTAssertEqual(monitor.pendingCommand, .pause)
        XCTAssertEqual(sender.messages.last, .command(.pause))

        monitor.receive(try data(.phaseChanged(.paused, at: clock.date), sequence: 2))
        XCTAssertNil(monitor.pendingCommand)

        XCTAssertTrue(monitor.send(.pause))
        monitor.receive(try data(.commandRejected(.pause, reason: "运动已暂停"), sequence: 3))
        XCTAssertNil(monitor.pendingCommand)
        XCTAssertEqual(monitor.commandError, "Apple Watch 无法暂停：运动已暂停")

        sender.isConnected = false
        XCTAssertFalse(monitor.send(.resume))
        XCTAssertEqual(monitor.connection, .disconnected(reason: nil))
    }

    func testEndedWorkoutIgnoresDisconnectAndCanReset() async throws {
        monitor.receive(try data(sync(.running), sequence: 1))
        monitor.receive(try data(.phaseChanged(.ended, at: clock.date), sequence: 2))
        monitor.transportDidDisconnect(reason: "session ended")
        XCTAssertEqual(monitor.connection, .connected)
        XCTAssertTrue(monitor.hasWorkout)

        monitor.reset()
        XCTAssertFalse(monitor.hasWorkout)
        XCTAssertEqual(monitor.connection, .waiting)
    }

    func testHistoryIsBounded() async throws {
        monitor.receive(try data(sync(.running), sequence: 1))
        for index in 0..<250 {
            monitor.receive(try data(.metrics(metrics(TimeInterval(index))), sequence: UInt64(index + 2)))
        }
        XCTAssertEqual(monitor.heartRateHistory.count, 100)
        XCTAssertEqual(monitor.heartRateHistory.last?.date, clock.date.addingTimeInterval(249))
    }

    func testElapsedTimeExtrapolatesOnlyWhileRunning() async throws {
        monitor.receive(try data(sync(.running), sequence: 1))
        monitor.receive(try data(.metrics(WorkoutMetricsSnapshot(timestamp: clock.date, elapsedTime: 100)), sequence: 2))
        XCTAssertEqual(monitor.elapsedTime(at: clock.date.addingTimeInterval(7)), 107)
        monitor.receive(try data(.phaseChanged(.paused, at: clock.date), sequence: 3))
        XCTAssertEqual(monitor.elapsedTime(at: clock.date.addingTimeInterval(7)), 100)
    }
}

// MARK: - 端到端（模拟 Watch ↔ 内存链路 ↔ iPhone）

@MainActor
final class SimulatedMirroredWorkoutTests: XCTestCase {
    func testFullWorkoutWithOutageAndRecovery() async {
        let clock = TestClock()
        let monitor = LiveWorkoutMonitor(dataOrigin: .simulated, now: { clock.date }, staleInterval: 10)
        let simulation = SimulatedMirroredWorkout(
            monitor: monitor,
            now: { clock.date },
            sleep: { _ in await Task.yield() },
            reconnectDelays: [.seconds(1), .seconds(1)]
        )
        let watch = simulation.watch

        await simulation.start(WorkoutConfigurationRequest(activity: .cycling, location: .outdoor))
        XCTAssertEqual(monitor.phase, .running)
        XCTAssertEqual(monitor.configuration?.activity, .cycling)
        XCTAssertEqual(monitor.dataOrigin, .simulated)

        for _ in 0..<30 {
            clock.advance(1)
            simulation.tick()
        }
        XCTAssertEqual(monitor.latestMetrics, watch.latestMetrics)
        XCTAssertEqual(monitor.heartRateHistory.count, 30)

        // iPhone 发命令暂停 → Watch 暂停 → iPhone 看到暂停。
        XCTAssertTrue(monitor.send(.pause))
        XCTAssertEqual(watch.phase, .paused)
        XCTAssertEqual(monitor.phase, .paused)
        XCTAssertNil(monitor.pendingCommand)
        XCTAssertTrue(monitor.send(.resume))
        XCTAssertEqual(monitor.phase, .running)

        // 断线：两端都感知到；Watch 继续记录。
        simulation.beginOutage()
        XCTAssertEqual(monitor.connection, .disconnected(reason: "模拟：Apple Watch 与 iPhone 断开"))
        XCTAssertFalse(watch.isMirroringConnected)
        for _ in 0..<20 {
            clock.advance(1)
            simulation.tick()
        }
        XCTAssertGreaterThan(watch.latestMetrics!.elapsedTime, monitor.latestMetrics!.elapsedTime)
        XCTAssertFalse(monitor.send(.pause))

        // 断线期间重连全部失败 → Watch 提示镜像不可用，但运动继续。
        await watch.waitForPendingWork()
        XCTAssertEqual(watch.lastError, .mirroringUnavailable)
        XCTAssertEqual(watch.phase, .running)

        // 一轮重连失败后，慢速重试间隔内不会再尝试。
        let attempts = simulation.driver.reconnectAttempts
        clock.advance(10)
        simulation.tick()
        await watch.waitForPendingWork()
        XCTAssertEqual(simulation.driver.reconnectAttempts, attempts)

        // 恢复：慢速重试触发重连成功，iPhone 追上状态。
        simulation.endOutage()
        clock.advance(60)
        simulation.tick()
        await watch.waitForPendingWork()
        XCTAssertTrue(watch.isMirroringConnected)
        XCTAssertNil(watch.lastError)
        XCTAssertEqual(monitor.connection, .connected)
        XCTAssertEqual(monitor.latestMetrics?.elapsedTime, watch.latestMetrics?.elapsedTime)

        // iPhone 结束运动。
        XCTAssertTrue(monitor.send(.end))
        await watch.waitForPendingWork()
        XCTAssertEqual(watch.phase, .ended)
        XCTAssertEqual(monitor.phase, .ended)
        XCTAssertEqual(watch.completedWorkout?.activity, .cycling)
        XCTAssertEqual(watch.completedWorkout?.sourceName, SimulatedWorkoutSessionDriver.sourceName)
    }

    func testDelayedAndReorderedDeliveryConverges() async {
        let clock = TestClock()
        let monitor = LiveWorkoutMonitor(dataOrigin: .simulated, now: { clock.date })
        let simulation = SimulatedMirroredWorkout(monitor: monitor, now: { clock.date }, sleep: { _ in await Task.yield() })
        await simulation.start(WorkoutConfigurationRequest(activity: .running, location: .outdoor))

        simulation.link.deliversImmediately = false
        for _ in 0..<50 {
            clock.advance(1)
            simulation.tick()
        }
        simulation.link.flush(reversed: true)

        // 倒序送达时只有最新一条被接受，其余作为过期消息丢弃，最终状态与 Watch 一致。
        XCTAssertEqual(monitor.latestMetrics, simulation.watch.latestMetrics)
        XCTAssertEqual(monitor.droppedMessageCount, 49)
    }
}
