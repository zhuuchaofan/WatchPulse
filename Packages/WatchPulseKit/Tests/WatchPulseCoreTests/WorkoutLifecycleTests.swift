import Foundation
import XCTest
@testable import WatchPulseCore
import WatchPulseShared

/// 代码审查 P0 / P1 的回归测试：结束与保存的语义、结束流程顺序、镜像连接确认。
@MainActor
final class WorkoutLifecycleTests: XCTestCase {
    private let running = WorkoutConfigurationRequest(activity: .running, location: .outdoor)

    private func makeSimulation(clock: TestClock) -> SimulatedMirroredWorkout {
        let monitor = LiveWorkoutMonitor(dataOrigin: .simulated, now: { clock.date })
        return SimulatedMirroredWorkout(monitor: monitor, now: { clock.date }, sleep: { _ in await Task.yield() })
    }

    // MARK: - P0：结束 ≠ 保存成功

    func testSaveFailureIsReportedToPhoneAndNeverShownAsSaved() async {
        let clock = TestClock()
        let simulation = makeSimulation(clock: clock)
        simulation.driver.endError = .saveFailed(reason: "磁盘已满")
        await simulation.start(running)
        clock.advance(30)
        simulation.tick()

        XCTAssertTrue(simulation.monitor.send(.end))
        await simulation.watch.waitForPendingWork()

        XCTAssertEqual(simulation.watch.phase, .ended)
        XCTAssertNil(simulation.watch.completedWorkout)
        guard case .failed(let reason) = simulation.watch.saveStatus else {
            return XCTFail("watch saveStatus = \(simulation.watch.saveStatus)")
        }
        XCTAssertTrue(reason.contains("磁盘已满"))
        XCTAssertEqual(simulation.monitor.saveStatus, simulation.watch.saveStatus)
        XCTAssertEqual(simulation.monitor.phase, .ended)
    }

    func testSaveSuccessIsReportedBeforeSessionEnds() async {
        let clock = TestClock()
        let driver = SimulatedWorkoutSessionDriver()
        let sender = RecordingSender()
        let controller = WorkoutSessionController(driver: driver, sender: sender, now: { clock.date })
        await controller.start(running)
        clock.advance(60)
        driver.advance(to: clock.date)
        var messagesSentBeforeEndSession = -1
        driver.onEndSession = { messagesSentBeforeEndSession = sender.sent.count }

        await controller.end()

        let record = try? XCTUnwrap(controller.completedWorkout)
        XCTAssertEqual(controller.saveStatus, .saved(workoutID: record?.id))
        // 驱动调用顺序：先停止并保存，确认结果后才结束会话（会话结束后镜像连接关闭）。
        XCTAssertEqual(driver.lifecycleLog, ["start", "stopAndSave", "endSession"])

        let messages = sender.messages
        let savingIndex = messages.firstIndex { message in
            if case .stateSync(let snapshot) = message { return snapshot.saveStatus == .saving }
            return false
        }
        let resultIndex = messages.firstIndex { message in
            if case .stateSync(let snapshot) = message {
                return snapshot.phase == .ended && snapshot.saveStatus == .saved(workoutID: record?.id)
            }
            return false
        }
        XCTAssertNotNil(savingIndex)
        XCTAssertNotNil(resultIndex)
        XCTAssertLessThan(savingIndex ?? .max, resultIndex ?? .min)
        // 最终“已结束 + 保存结果”在结束会话（镜像关闭）之前已经发出并确认。
        XCTAssertEqual(controller.finalStateDelivered, true)
        XCTAssertLessThan(resultIndex ?? .max, messagesSentBeforeEndSession)
    }

    func testFinishWithoutRecordIsTreatedAsFailure() async {
        let driver = SimulatedWorkoutSessionDriver()
        driver.returnsNoRecordOnSave = true
        let controller = WorkoutSessionController(driver: driver, sender: RecordingSender())
        await controller.start(running)
        await controller.end()
        guard case .failed = controller.saveStatus else {
            return XCTFail("saveStatus = \(controller.saveStatus)")
        }
        XCTAssertEqual(controller.phase, .ended)
        XCTAssertEqual(driver.lifecycleLog.last, "endSession")
    }

    func testPhoneWithoutSaveResultDoesNotClaimSaved() async throws {
        let clock = TestClock()
        let monitor = LiveWorkoutMonitor(dataOrigin: .healthKit, now: { clock.date })
        let session = UUID()
        func send(_ message: WorkoutMirroringMessage, _ sequence: UInt64) throws {
            monitor.receive(try WorkoutMirroringCodec.encode(WorkoutMirroringEnvelope(
                sessionID: session, sequence: sequence, sentAt: clock.date, message: message
            )))
        }
        try send(.stateSync(WorkoutStateSnapshot(configuration: running, phase: .running, startDate: clock.date, metrics: nil)), 1)
        XCTAssertEqual(monitor.saveStatus, .pending)
        try send(.stateSync(WorkoutStateSnapshot(configuration: running, phase: .stopped, startDate: clock.date, metrics: nil, saveStatus: .saving)), 2)
        XCTAssertEqual(monitor.saveStatus, .saving)
        // 保存结果消息丢失（例如连接中断），只收到结束。
        try send(.phaseChanged(.ended, at: clock.date), 3)
        XCTAssertEqual(monitor.phase, .ended)
        XCTAssertEqual(monitor.saveStatus, .saving)
        XCTAssertFalse(monitor.saveStatus.isSaved)
    }

    func testNewWorkoutResetsSaveStatus() async throws {
        let clock = TestClock()
        let simulation = makeSimulation(clock: clock)
        await simulation.start(running)
        await simulation.watch.end()
        XCTAssertTrue(simulation.monitor.saveStatus.isSaved)

        simulation.watch.dismissSummary()
        XCTAssertEqual(simulation.watch.saveStatus, .pending)
        clock.advance(600)
        await simulation.start(running)
        XCTAssertEqual(simulation.monitor.saveStatus, .pending)
        XCTAssertEqual(simulation.monitor.phase, .running)
    }

    // MARK: - P1：镜像连接必须由驱动确认

    func testSenderPresenceAloneIsNotAConnection() async {
        let driver = SimulatedWorkoutSessionDriver()
        driver.confirmsMirroringOnStart = false
        let sender = RecordingSender()
        let controller = WorkoutSessionController(
            driver: driver,
            sender: sender,
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )

        await controller.start(running)

        XCTAssertEqual(controller.phase, .running)
        XCTAssertFalse(controller.isMirroringConnected)
        XCTAssertTrue(controller.isReconnecting)
        XCTAssertTrue(sender.sent.isEmpty, "未确认连接前不应发送")

        // 驱动稍后确认镜像建立：立即同步完整状态。
        driver.confirmMirroringConnected()
        XCTAssertTrue(controller.isMirroringConnected)
        XCTAssertFalse(controller.isReconnecting)
        guard case .stateSync(let snapshot)? = sender.messages.first else {
            return XCTFail("expected stateSync, got \(sender.messages)")
        }
        XCTAssertEqual(snapshot.phase, .running)
    }

    func testRecoveryWaitsForMirroringConfirmation() async {
        let clock = TestClock()
        let driver = SimulatedWorkoutSessionDriver()
        driver.confirmsMirroringOnStart = false
        driver.recoverableSnapshot = WorkoutStateSnapshot(
            configuration: running,
            phase: .running,
            startDate: clock.date.addingTimeInterval(-60),
            metrics: WorkoutMetricsSnapshot(timestamp: clock.date, elapsedTime: 60)
        )
        let sender = RecordingSender()
        let controller = WorkoutSessionController(
            driver: driver,
            sender: sender,
            now: { clock.date },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )

        await controller.recoverIfNeeded()

        XCTAssertEqual(controller.phase, .running)
        XCTAssertFalse(controller.isMirroringConnected)
        XCTAssertTrue(sender.sent.isEmpty)
        driver.confirmMirroringConnected()
        XCTAssertTrue(controller.isMirroringConnected)
        XCTAssertEqual(sender.sent.count, 1)
    }
}

/// 代码审查 P1：连接超时检测不能依赖某个页面是否打开。
@MainActor
final class ConnectionWatchdogTests: XCTestCase {
    func testWatchdogDetectsStaleConnectionWithoutAnyView() async throws {
        let clock = TestClock()
        let monitor = LiveWorkoutMonitor(dataOrigin: .healthKit, now: { clock.date }, staleInterval: 10)
        monitor.receive(try WorkoutMirroringCodec.encode(WorkoutMirroringEnvelope(
            sessionID: UUID(), sequence: 1, sentAt: clock.date,
            message: .stateSync(WorkoutStateSnapshot(
                configuration: WorkoutConfigurationRequest(activity: .running, location: .outdoor),
                phase: .running, startDate: clock.date, metrics: nil
            ))
        )))
        XCTAssertEqual(monitor.connection, .connected)

        let start = clock.date
        var staleObservedAt: Date?
        // 每次“睡眠”推进 5 秒；在推进前记录看门狗上一轮是否已判定为信号弱。
        monitor.startConnectionWatchdog(interval: .seconds(1)) { _ in
            if staleObservedAt == nil, monitor.connection == .stale {
                staleObservedAt = clock.date
            }
            clock.advance(5)
            await Task.yield()
        }
        XCTAssertTrue(monitor.isConnectionWatchdogRunning)
        for _ in 0..<1_000 where staleObservedAt == nil {
            await Task.yield()
        }
        XCTAssertEqual(monitor.connection, .stale)
        // 阈值 10 秒、每轮 5 秒：第 3 轮（15 秒）检查时必须已判定为信号弱。
        XCTAssertEqual(staleObservedAt.map { $0.timeIntervalSince(start) }, 15)

        monitor.stopConnectionWatchdog()
        XCTAssertFalse(monitor.isConnectionWatchdogRunning)
    }

    func testWatchdogStartIsIdempotent() async {
        let monitor = LiveWorkoutMonitor(dataOrigin: .healthKit)
        var starts = 0
        let sleep: @MainActor (Duration) async throws -> Void = { _ in
            starts += 1
            try await Task.sleep(for: .seconds(3600))
        }
        monitor.startConnectionWatchdog(interval: .seconds(1), sleep: sleep)
        monitor.startConnectionWatchdog(interval: .seconds(1), sleep: sleep)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(starts, 1)
        monitor.stopConnectionWatchdog()
    }
}
