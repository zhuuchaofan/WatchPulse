import Foundation
import HealthKit
import WatchPulseCore
import WatchPulseShared

/// 基于 `HKWorkoutSession` + `HKLiveWorkoutBuilder` 的真实运动驱动，同时负责把数据发送到 iPhone 镜像会话。
///
/// 流程参考 Apple “Building a multidevice workout app” 与 “Running workout sessions”：
/// - 开始：创建会话 → `startMirroringToCompanionDevice()` → `startActivity(with:)` → `beginCollection(at:)`；
/// - 结束：`stopActivity(with:)` → 等待 `.stopped` → `endCollection(at:)` → `finishWorkout()`（确认保存）
///   → 状态机把保存结果发给 iPhone → `endSession()` 调用 `session.end()` 并释放引用；
/// - 数据通过 `sendToRemoteWorkoutSession(data:)` 发送，iPhone 数据从
///   `workoutSession(_:didReceiveDataFromRemoteWorkoutSession:)` 收到。
///
/// HealthKit 回调发生在后台线程，统一经主队列（保持顺序）转交给状态机。
@MainActor
final class HealthKitWorkoutSessionDriver: NSObject, WorkoutSessionDriver, WorkoutMirroringSender {
    var eventHandler: ((WorkoutDriverEvent) -> Void)?
    let dataOrigin: HealthDataOrigin = .healthKit

    private let healthStore: HKHealthStore
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    /// 会话进入 `.stopped` 的时间（由委托回调写入）。
    private var stoppedDate: Date?
    private var stoppedWaiter: CheckedContinuation<Date?, Never>?
    /// 等待 `.stopped` 的上限，避免回调缺失时永久挂起。
    private let stopTimeout: Duration = .seconds(10)

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
        super.init()
    }

    // MARK: - WorkoutSessionDriver

    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw WorkoutSessionError.healthDataUnavailable }
        do {
            try await Self.requestAuthorization(UncheckedSendableBox(healthStore))
        } catch {
            throw WorkoutSessionError.authorizationFailed(reason: error.localizedDescription)
        }
    }

    func start(_ request: WorkoutConfigurationRequest, at date: Date) async throws {
        guard session == nil else {
            throw WorkoutSessionError.invalidTransition(from: .running, action: "开始")
        }
        let configuration = HealthKitWorkoutMapping.configuration(from: request)
        let session: HKWorkoutSession
        do {
            session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
        } catch {
            throw WorkoutSessionError.sessionStartFailed(reason: error.localizedDescription)
        }
        let builder = session.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
        session.delegate = self
        builder.delegate = self
        self.session = session
        self.builder = builder
        stoppedDate = nil

        // 镜像失败不阻止运动：状态机会在后台重连。
        await startMirroringAndReport(session)

        session.startActivity(with: date)
        do {
            try await Self.beginCollection(UncheckedSendableBox(builder), at: date)
        } catch {
            session.end()
            self.session = nil
            self.builder = nil
            throw WorkoutSessionError.sessionStartFailed(reason: error.localizedDescription)
        }
    }

    func pause(at date: Date) {
        session?.pause()
    }

    func resume(at date: Date) {
        session?.resume()
    }

    func stopAndSave(at date: Date) async throws -> WorkoutRecord {
        guard let session, let builder else { throw WorkoutSessionError.noActiveSession }

        let observedStop: Date?
        switch session.state {
        case .stopped, .ended:
            observedStop = stoppedDate
        default:
            session.stopActivity(with: date)
            observedStop = await waitUntilStopped()
        }
        // 超时后复核会话真实状态：仍未停止就明确失败，不当作已正常停止继续保存。
        let stopDate = try WorkoutStopResolution.stopDate(
            observed: observedStop,
            stateAfterWait: HealthKitWorkoutMapping.phase(from: session.state),
            requested: date
        )

        do {
            try await Self.endCollection(UncheckedSendableBox(builder), at: stopDate)
            guard let record = try await Self.finishWorkout(UncheckedSendableBox(builder)) else {
                throw WorkoutSessionError.saveFailed(reason: "HealthKit 未返回运动记录")
            }
            return record
        } catch let error as WorkoutSessionError {
            throw error
        } catch {
            throw WorkoutSessionError.saveFailed(reason: error.localizedDescription)
        }
    }

    func endSession() {
        resumeStoppedWaiter(with: nil)
        session?.end()
        session = nil
        builder = nil
        stoppedDate = nil
    }

    func reconnectMirroring() async throws {
        guard let session else { throw WorkoutSessionError.noActiveSession }
        try await Self.startMirroring(UncheckedSendableBox(session))
        eventHandler?(.mirroringConnected)
    }

    func recoverActiveSession() async throws -> WorkoutStateSnapshot? {
        guard session == nil else { return nil }
        guard let recovered = try await Self.recoverSession(UncheckedSendableBox(healthStore))?.value else {
            return nil
        }
        let builder = recovered.associatedWorkoutBuilder()
        builder.dataSource = HKLiveWorkoutDataSource(
            healthStore: healthStore,
            workoutConfiguration: recovered.workoutConfiguration
        )
        recovered.delegate = self
        builder.delegate = self
        session = recovered
        self.builder = builder
        stoppedDate = nil

        await startMirroringAndReport(recovered)

        return WorkoutStateSnapshot(
            configuration: HealthKitWorkoutMapping.request(from: recovered.workoutConfiguration),
            phase: HealthKitWorkoutMapping.phase(from: recovered.state),
            startDate: recovered.startDate,
            metrics: Self.metrics(from: builder, at: Date())
        )
    }

    // MARK: - WorkoutMirroringSender

    func send(_ data: Data) throws {
        guard let session else { throw WorkoutSessionError.notConnected }
        Self.sendToRemote(UncheckedSendableBox(session), data: data) { [self] reason in
            emit(.mirroringDisconnected(reason: reason))
        }
    }

    /// 等待 `sendToRemoteWorkoutSession` 的完成回调，用于结束会话前的最后一条消息。
    func sendAndConfirm(_ data: Data) async throws {
        guard let session else { throw WorkoutSessionError.notConnected }
        try await Self.sendToRemoteConfirmed(UncheckedSendableBox(session), data: data)
    }

    // MARK: - Private

    /// 开始镜像，并把结果作为连接事件上报：只有成功后状态机才认为已连接。
    private func startMirroringAndReport(_ session: HKWorkoutSession) async {
        do {
            try await Self.startMirroring(UncheckedSendableBox(session))
            eventHandler?(.mirroringConnected)
        } catch {
            eventHandler?(.mirroringDisconnected(reason: error.localizedDescription))
        }
    }

    /// 等待委托回调报告 `.stopped`；超时返回 `nil`。
    private func waitUntilStopped() async -> Date? {
        if let stoppedDate { return stoppedDate }
        let timeout = stopTimeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resumeStoppedWaiter(with: nil)
        }
        defer { timeoutTask.cancel() }
        return await withCheckedContinuation { continuation in
            if let stoppedDate {
                continuation.resume(returning: stoppedDate)
            } else {
                stoppedWaiter = continuation
            }
        }
    }

    private func resumeStoppedWaiter(with date: Date?) {
        guard let waiter = stoppedWaiter else { return }
        stoppedWaiter = nil
        waiter.resume(returning: date)
    }

    private func handleStateChange(_ state: HKWorkoutSessionState, at date: Date) {
        if state == .stopped {
            stoppedDate = date
            resumeStoppedWaiter(with: date)
        }
        eventHandler?(.phaseChanged(HealthKitWorkoutMapping.phase(from: state), at: date))
    }

    /// 按到达顺序把事件交给主线程上的状态机。
    nonisolated private func emit(_ event: WorkoutDriverEvent) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.eventHandler?(event)
            }
        }
    }

    nonisolated static func metrics(from builder: HKLiveWorkoutBuilder, at date: Date) -> WorkoutMetricsSnapshot {
        let heartRateStatistics = builder.statistics(for: HKQuantityType(.heartRate))
        let heartRate = heartRateStatistics?
            .mostRecentQuantity()?
            .doubleValue(for: HealthKitTypes.beatsPerMinute)
        let energy = builder.statistics(for: HKQuantityType(.activeEnergyBurned))?
            .sumQuantity()?
            .doubleValue(for: .kilocalorie())
        let distance = (builder.statistics(for: HKQuantityType(.distanceWalkingRunning))
            ?? builder.statistics(for: HKQuantityType(.distanceCycling)))?
            .sumQuantity()?
            .doubleValue(for: .meter())
        return WorkoutMetricsSnapshot(
            timestamp: date,
            elapsedTime: builder.elapsedTime(at: date),
            heartRateBPM: heartRate,
            activeEnergyKilocalories: energy,
            distanceMeters: distance,
            heartRateDate: heartRate == nil ? nil : heartRateStatistics?.mostRecentQuantityDateInterval()?.end
        )
    }

    // 以下包装在非隔离上下文中调用 HealthKit 的回调式 API，避免回调被推断为主线程隔离。

    nonisolated private static func requestAuthorization(_ store: UncheckedSendableBox<HKHealthStore>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.value.requestAuthorization(
                toShare: HealthKitTypes.workoutShareTypes,
                read: HealthKitTypes.readTypes
            ) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    nonisolated private static func startMirroring(_ session: UncheckedSendableBox<HKWorkoutSession>) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.value.startMirroringToCompanionDevice { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? WorkoutSessionError.notConnected)
                }
            }
        }
    }

    nonisolated private static func beginCollection(_ builder: UncheckedSendableBox<HKLiveWorkoutBuilder>, at date: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.value.beginCollection(withStart: date) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? WorkoutSessionError.sessionStartFailed(reason: "beginCollection"))
                }
            }
        }
    }

    nonisolated private static func endCollection(_ builder: UncheckedSendableBox<HKLiveWorkoutBuilder>, at date: Date) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            builder.value.endCollection(withEnd: date) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? WorkoutSessionError.saveFailed(reason: "endCollection"))
                }
            }
        }
    }

    nonisolated private static func finishWorkout(_ builder: UncheckedSendableBox<HKLiveWorkoutBuilder>) async throws -> WorkoutRecord? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WorkoutRecord?, Error>) in
            builder.value.finishWorkout { workout, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: workout.map(HealthKitWorkoutMapping.record(from:)))
                }
            }
        }
    }

    nonisolated private static func recoverSession(
        _ store: UncheckedSendableBox<HKHealthStore>
    ) async throws -> UncheckedSendableBox<HKWorkoutSession>? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UncheckedSendableBox<HKWorkoutSession>?, Error>) in
            store.value.recoverActiveWorkoutSession { session, error in
                if let session {
                    continuation.resume(returning: UncheckedSendableBox(session))
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    nonisolated private static func sendToRemoteConfirmed(
        _ session: UncheckedSendableBox<HKWorkoutSession>,
        data: Data
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.value.sendToRemoteWorkoutSession(data: data) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? WorkoutSessionError.notConnected)
                }
            }
        }
    }

    nonisolated private static func sendToRemote(
        _ session: UncheckedSendableBox<HKWorkoutSession>,
        data: Data,
        onFailure: @escaping @Sendable (String?) -> Void
    ) {
        session.value.sendToRemoteWorkoutSession(data: data) { success, error in
            if !success {
                onFailure(error?.localizedDescription)
            }
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension HealthKitWorkoutSessionDriver: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.handleStateChange(toState, at: date)
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        emit(.failed(reason: error.localizedDescription))
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        for item in data {
            emit(.remoteDataReceived(item))
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        emit(.mirroringDisconnected(reason: error?.localizedDescription))
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension HealthKitWorkoutSessionDriver: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        emit(.metrics(Self.metrics(from: workoutBuilder, at: Date())))
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
