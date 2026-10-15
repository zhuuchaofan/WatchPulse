import Foundation
import XCTest
@testable import WatchPulseCore
import WatchPulseShared

/// 复审 P0 / P1：最终“已结束 + 保存结果”必须在镜像关闭前送达并确认；模拟链路必须像真实会话一样在结束后关闭。
@MainActor
final class FinalStateDeliveryTests: XCTestCase {
    private let running = WorkoutConfigurationRequest(activity: .running, location: .outdoor)

    private func makeSimulation(clock: TestClock) -> SimulatedMirroredWorkout {
        let monitor = LiveWorkoutMonitor(dataOrigin: .simulated, now: { clock.date })
        return SimulatedMirroredWorkout(monitor: monitor, now: { clock.date }, sleep: { _ in await Task.yield() })
    }

    func testPhoneReceivesFinalEndedStateBeforeSessionCloses() async {
        let clock = TestClock()
        let simulation = makeSimulation(clock: clock)
        await simulation.start(running)
        clock.advance(30)
        simulation.tick()

        var phoneStateAtEndSession: (WorkoutSessionPhase, WorkoutSaveStatus)?
        simulation.driver.onEndSession = { [monitor = simulation.monitor] in
            phoneStateAtEndSession = (monitor.phase, monitor.saveStatus)
        }

        await simulation.watch.end()

        // 关闭会话的那一刻，iPhone 已经是“已结束 + 已保存”。
        XCTAssertEqual(phoneStateAtEndSession?.0, .ended)
        XCTAssertEqual(phoneStateAtEndSession?.1.isSaved, true)
        XCTAssertEqual(simulation.watch.finalStateDelivered, true)
        XCTAssertEqual(simulation.monitor.phase, .ended)
        XCTAssertTrue(simulation.monitor.saveStatus.isSaved)
    }

    func testSessionEndClosesSimulatedMirroring() async {
        let clock = TestClock()
        let simulation = makeSimulation(clock: clock)
        await simulation.start(running)
        await simulation.watch.end()

        // 与真实 HealthKit 一致：会话结束后镜像关闭，任何一端都不能再发送。
        XCTAssertFalse(simulation.link.isConnected)
        XCTAssertThrowsError(try simulation.link.watchEndpoint.send(Data("{}".utf8)))
        XCTAssertThrowsError(try simulation.link.phoneEndpoint.send(Data("{}".utf8)))
        XCTAssertFalse(simulation.watch.isMirroringConnected)
    }

    func testFinalDeliveryFailureLeavesPhoneWithExplicitUnknownState() async {
        let clock = TestClock()
        let simulation = makeSimulation(clock: clock)
        await simulation.start(running)
        // 保存完成后、发送最终状态前链路中断。
        simulation.driver.onStopAndSave = { [link = simulation.link] in
            link.disconnect(reason: "模拟：结束时断开")
        }

        await simulation.watch.end()

        XCTAssertTrue(simulation.watch.saveStatus.isSaved, "Watch 端保存成功")
        XCTAssertEqual(simulation.watch.finalStateDelivered, false)
        XCTAssertEqual(simulation.watch.phase, .ended)
        // iPhone 收到镜像会话结束：明确进入“已结束”，但保存结果未知（不显示已保存）。
        XCTAssertEqual(simulation.monitor.phase, .ended)
        XCTAssertFalse(simulation.monitor.saveStatus.isSaved)
        XCTAssertFalse(simulation.monitor.canSendCommands)
    }

    func testStoppedPhaseOffersNoControls() async throws {
        let clock = TestClock()
        let monitor = LiveWorkoutMonitor(dataOrigin: .healthKit, now: { clock.date })
        monitor.attach(sender: RecordingSender())
        monitor.receive(try WorkoutMirroringCodec.encode(WorkoutMirroringEnvelope(
            sessionID: UUID(), sequence: 1, sentAt: clock.date,
            message: .stateSync(WorkoutStateSnapshot(configuration: running, phase: .stopped, startDate: clock.date, metrics: nil, saveStatus: .saving))
        )))
        XCTAssertFalse(monitor.canSendCommands)
        XCTAssertFalse(monitor.send(.pause))
        XCTAssertFalse(monitor.send(.end))
        XCTAssertNotNil(monitor.commandError)
    }

    func testRemoteSessionEndWithoutFinalMessage() async throws {
        let clock = TestClock()
        let monitor = LiveWorkoutMonitor(dataOrigin: .healthKit, now: { clock.date })
        monitor.receive(try WorkoutMirroringCodec.encode(WorkoutMirroringEnvelope(
            sessionID: UUID(), sequence: 1, sentAt: clock.date,
            message: .stateSync(WorkoutStateSnapshot(configuration: running, phase: .running, startDate: clock.date, metrics: nil))
        )))
        monitor.remoteSessionEnded()
        XCTAssertEqual(monitor.phase, .ended)
        XCTAssertEqual(monitor.saveStatus, .pending)
        XCTAssertFalse(monitor.saveStatus.isSaved)

        // 没有运动时收到结束通知不应凭空出现“已结束”。
        let idle = LiveWorkoutMonitor(dataOrigin: .healthKit)
        idle.remoteSessionEnded()
        XCTAssertEqual(idle.phase, .notStarted)
    }
}

/// 复审 P1：等待 `.stopped` 超时后的处理。
final class WorkoutStopResolutionTests: XCTestCase {
    private let requested = Date(timeIntervalSince1970: 1_000)
    private let observed = Date(timeIntervalSince1970: 1_002)

    func testUsesObservedStopDate() async {
        XCTAssertEqual(try WorkoutStopResolution.stopDate(observed: observed, stateAfterWait: .stopped, requested: requested), observed)
    }

    func testTimeoutButSessionActuallyStoppedUsesRequestedDate() async {
        XCTAssertEqual(try WorkoutStopResolution.stopDate(observed: nil, stateAfterWait: .stopped, requested: requested), requested)
        XCTAssertEqual(try WorkoutStopResolution.stopDate(observed: nil, stateAfterWait: .ended, requested: requested), requested)
    }

    func testTimeoutWhileStillRunningIsExplicitFailure() async {
        for state in [WorkoutSessionPhase.running, .paused, .prepared, .notStarted] {
            XCTAssertThrowsError(try WorkoutStopResolution.stopDate(observed: nil, stateAfterWait: state, requested: requested)) { error in
                guard case .saveFailed? = error as? WorkoutSessionError else {
                    return XCTFail("\(state): \(error)")
                }
            }
        }
    }
}
