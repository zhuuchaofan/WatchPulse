import Foundation
import HealthKit
import WatchPulseCore
import WatchPulseShared

/// iPhone 端接收 Apple Watch 镜像过来的 `HKWorkoutSession`，把数据交给 `LiveWorkoutMonitor`。
///
/// 必须在 App 启动早期调用 `start()`：系统可能为了投递镜像会话而在后台拉起 App。
@MainActor
final class HealthKitMirroringReceiver: NSObject, WorkoutMirroringSender {
    private let healthStore: HKHealthStore
    private let monitor: LiveWorkoutMonitor
    private var session: HKWorkoutSession?

    init(healthStore: HKHealthStore = HKHealthStore(), monitor: LiveWorkoutMonitor) {
        self.healthStore = healthStore
        self.monitor = monitor
        super.init()
        monitor.attach(sender: self)
    }

    func start() {
        Self.installMirroringHandler(on: UncheckedSendableBox(healthStore)) { [self] box in
            onMain { receiver in
                receiver.attach(box.value)
            }
        }
    }

    /// 在非隔离上下文中创建回调，避免它被推断为主线程隔离（HealthKit 会在后台线程调用）。
    nonisolated private static func installMirroringHandler(
        on store: UncheckedSendableBox<HKHealthStore>,
        handler: @escaping @Sendable (UncheckedSendableBox<HKWorkoutSession>) -> Void
    ) {
        store.value.workoutSessionMirroringStartHandler = { mirroredSession in
            handler(UncheckedSendableBox(mirroredSession))
        }
    }

    private func attach(_ mirroredSession: HKWorkoutSession) {
        session = mirroredSession
        mirroredSession.delegate = self
        monitor.sessionDidStart()
    }

    // MARK: - WorkoutMirroringSender

    func send(_ data: Data) throws {
        guard let session else { throw WorkoutSessionError.notConnected }
        Self.sendToRemote(UncheckedSendableBox(session), data: data) { [self] reason in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.monitor.transportDidDisconnect(reason: reason)
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

    nonisolated private func onMain(_ body: @escaping @MainActor @Sendable (HealthKitMirroringReceiver) -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                body(self)
            }
        }
    }
}

extension HealthKitMirroringReceiver: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        // 阶段以 Watch 发来的消息为准；镜像会话结束时释放引用。
        guard toState == .ended else { return }
        onMain { receiver in
            receiver.session = nil
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        let reason = error.localizedDescription
        onMain { receiver in
            receiver.monitor.transportDidDisconnect(reason: reason)
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        onMain { receiver in
            for item in data {
                receiver.monitor.receive(item)
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        let reason = error?.localizedDescription
        onMain { receiver in
            receiver.monitor.transportDidDisconnect(reason: reason)
        }
    }
}
