import Foundation
import XCTest
@testable import WatchPulseCore
import WatchPulseShared

/// 稳定性 / 压力测试：大量消息、乱序、重复、随机字节、长时间运动与反复断线。
@MainActor
final class StabilityTests: XCTestCase {
    func testMonitorConvergesUnderHeavyReorderingAndDuplication() async throws {
        let clock = TestClock()
        let monitor = LiveWorkoutMonitor(dataOrigin: .simulated, now: { clock.date }, historyLimit: 500)
        let session = UUID()
        let start = clock.date

        var envelopes: [WorkoutMirroringEnvelope] = [
            WorkoutMirroringEnvelope(sessionID: session, sequence: 1, sentAt: start, message: .stateSync(WorkoutStateSnapshot(
                configuration: WorkoutConfigurationRequest(activity: .running, location: .outdoor),
                phase: .running,
                startDate: start,
                metrics: nil
            ))),
        ]
        for index in 1...20_000 {
            envelopes.append(WorkoutMirroringEnvelope(
                sessionID: session,
                sequence: UInt64(index + 1),
                sentAt: start.addingTimeInterval(Double(index)),
                message: .metrics(WorkoutMetricsSnapshot(
                    timestamp: start.addingTimeInterval(Double(index)),
                    elapsedTime: Double(index),
                    heartRateBPM: 100 + Double(index % 80)
                ))
            ))
        }
        var generator = SeededRandomGenerator(seed: 99)
        // 第一条（状态同步）先到，其余消息局部打乱并插入 10% 的重复。
        var stream = [envelopes[0]]
        var rest = Array(envelopes.dropFirst())
        for blockStart in stride(from: 0, to: rest.count, by: 50) {
            let blockEnd = min(blockStart + 50, rest.count)
            rest[blockStart..<blockEnd].shuffle(using: &generator)
        }
        for envelope in rest {
            stream.append(envelope)
            if generator.next() % 10 == 0 {
                stream.append(envelope)
            }
        }
        stream.append(envelopes.last!)

        for envelope in stream {
            monitor.receive(try WorkoutMirroringCodec.encode(envelope))
        }

        // 最后一条（序号最大）一定会被接受。
        XCTAssertEqual(monitor.latestMetrics?.elapsedTime, 20_000)
        XCTAssertEqual(monitor.phase, .running)
        XCTAssertLessThanOrEqual(monitor.heartRateHistory.count, 500)
        XCTAssertEqual(monitor.heartRateHistory.map(\.date), monitor.heartRateHistory.map(\.date).sorted())
        XCTAssertGreaterThan(monitor.droppedMessageCount, 0)
        XCTAssertEqual(monitor.invalidMessageCount, 0)
    }

    func testRandomBytesNeverCrashEitherSide() async throws {
        var generator = SeededRandomGenerator(seed: 1)
        let monitor = LiveWorkoutMonitor(dataOrigin: .simulated)
        let driver = SimulatedWorkoutSessionDriver()
        let controller = WorkoutSessionController(driver: driver, sender: RecordingSender())
        await controller.start(WorkoutConfigurationRequest(activity: .walking, location: .outdoor))

        let valid = try WorkoutMirroringCodec.encode(WorkoutMirroringEnvelope(
            sessionID: UUID(), sequence: 1, sentAt: Date(), message: .command(.pause)
        ))
        for round in 0..<2_000 {
            var bytes: [UInt8]
            if round % 2 == 0 {
                bytes = (0..<Int(generator.next() % 256)).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
            } else {
                // 在合法消息上随机翻转若干字节。
                bytes = Array(valid)
                for _ in 0..<3 {
                    let index = Int(generator.next() % UInt64(bytes.count))
                    bytes[index] = UInt8(truncatingIfNeeded: generator.next())
                }
            }
            monitor.receive(Data(bytes))
            driver.deliverRemoteData(Data(bytes))
        }
        XCTAssertGreaterThan(monitor.invalidMessageCount, 1_000)
        XCTAssertGreaterThan(controller.invalidMessageCount, 1_000)
        XCTAssertTrue(controller.phase.isActive)
    }

    /// 模拟 2 小时运动，期间多次随机断线与恢复，验证两端最终一致、计时单调、Watch 端运动从不中断。
    func testLongWorkoutWithRepeatedOutagesConverges() async {
        let clock = TestClock()
        let monitor = LiveWorkoutMonitor(dataOrigin: .simulated, now: { clock.date }, staleInterval: 12)
        let simulation = SimulatedMirroredWorkout(
            monitor: monitor,
            now: { clock.date },
            sleep: { _ in await Task.yield() },
            reconnectDelays: [.seconds(2), .seconds(5)]
        )
        let watch = simulation.watch
        await simulation.start(WorkoutConfigurationRequest(activity: .running, location: .outdoor))

        var generator = SeededRandomGenerator(seed: 5)
        var lastWatchElapsed: TimeInterval = 0
        var outageCount = 0
        for second in 0..<(2 * 3_600) {
            clock.advance(1)
            if !simulation.isOutageActive, generator.next() % 600 == 0 {
                simulation.beginOutage()
                outageCount += 1
            } else if simulation.isOutageActive, generator.next() % 90 == 0 {
                simulation.endOutage()
            }
            if second % 900 == 450, watch.phase == .running {
                watch.pause()
            } else if second % 900 == 480, watch.phase == .paused {
                watch.resume()
            }
            simulation.tick()
            if second % 30 == 0 {
                await watch.waitForPendingWork()
            }
            let elapsed = watch.elapsedTime(at: clock.date)
            XCTAssertGreaterThanOrEqual(elapsed, lastWatchElapsed - 0.001)
            lastWatchElapsed = elapsed
            XCTAssertTrue(watch.phase.isActive)
        }
        XCTAssertGreaterThan(outageCount, 3, "随机种子应产生多次断线")

        // 结束断线，等待慢速重连。
        simulation.endOutage()
        for _ in 0..<120 {
            clock.advance(1)
            simulation.tick()
            await watch.waitForPendingWork()
        }
        XCTAssertTrue(watch.isMirroringConnected)
        XCTAssertEqual(monitor.connection, .connected)
        XCTAssertEqual(monitor.phase, watch.phase)
        XCTAssertEqual(monitor.latestMetrics, watch.latestMetrics)

        XCTAssertTrue(monitor.send(.end))
        await watch.waitForPendingWork()
        XCTAssertEqual(watch.phase, .ended)
        XCTAssertEqual(monitor.phase, .ended)
        XCTAssertGreaterThan(watch.completedWorkout?.duration ?? 0, 6_000)
    }

    func testRapidTrendPeriodSwitchingKeepsLatestSelection() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let service = MockHealthDataService.demo(now: now, calendar: calendar)
        let viewModel = MetricTrendViewModel(kind: .stepCount, service: service, calendar: calendar, now: { now })

        await withTaskGroup(of: Void.self) { group in
            for period in [TrendPeriod.month, .week, .quarter, .month, .quarter] {
                group.addTask { await viewModel.select(period) }
            }
        }
        await viewModel.load()

        XCTAssertEqual(viewModel.state.value?.period, viewModel.period)
        XCTAssertEqual(viewModel.state.value?.points.count, viewModel.period.dayCount)
    }

    func testStaleTrendResponseIsDiscarded() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let calendar = Calendar(identifier: .gregorian)
        let points = SimulatedHealthData(now: now, calendar: calendar).trend(for: .stepCount, days: 90)
        let service = MockHealthDataService(trends: [.stepCount: .value(points)], responseDelay: .milliseconds(30))
        let viewModel = MetricTrendViewModel(kind: .stepCount, service: service, calendar: calendar, now: { now })

        async let slow: Void = viewModel.select(.quarter)
        try? await Task.sleep(for: .milliseconds(5))
        async let fast: Void = viewModel.select(.week)
        _ = await (slow, fast)

        XCTAssertEqual(viewModel.period, .week)
        XCTAssertEqual(viewModel.state.value?.points.count, 7)
    }

    func testDashboardRepeatedRefreshIsStable() async {
        let service = MockHealthDataService.demo(now: Date(timeIntervalSince1970: 1_800_000_000))
        let viewModel = HealthOverviewViewModel(service: service)
        for _ in 0..<200 {
            await viewModel.load()
        }
        XCTAssertNotNil(viewModel.state.value)
        XCTAssertEqual(service.fetchCount, 200)
    }
}
