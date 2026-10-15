import CoreLocation
import Foundation
import WatchKit
import WatchPulseCore
import WatchPulseShared

/// 基于 `CLLocationManager` 的定位提供者（Apple Watch 本机 GPS）。只在室外骑行时由 `CyclingSpeedTracker` 启动。
///
/// 定位回调在后台线程，统一经主队列按顺序转交。运动期间的后台定位依赖 `WKBackgroundModes`
/// 中的 `workout-processing`，需真机验证（见 DEVICE_VALIDATION.md）。
@MainActor
final class CoreLocationFixProvider: NSObject, LocationFixProvider {
    let dataOrigin: HealthDataOrigin = .healthKit
    var fixHandler: ((LocationFix) -> Void)?
    var authorizationHandler: ((LocationAuthorization) -> Void)?

    private let manager: CLLocationManager

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
    }

    var authorization: LocationAuthorization {
        Self.map(manager.authorizationStatus)
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func startUpdates() {
        manager.startUpdatingLocation()
    }

    func stopUpdates() {
        manager.stopUpdatingLocation()
    }

    nonisolated static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }
}

extension CoreLocationFixProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fixes = locations.map {
            LocationFix(
                timestamp: $0.timestamp,
                speed: $0.speed,
                speedAccuracy: $0.speedAccuracy,
                horizontalAccuracy: $0.horizontalAccuracy
            )
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for fix in fixes {
                    self.fixHandler?(fix)
                }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = Self.map(manager.authorizationStatus)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.authorizationHandler?(status)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 定位暂时失败（例如室内无信号）：不处理，测速器会因没有新样本把速度标为过期。
    }
}

/// 心率区间提醒的震动：高于区间提示“降低”，低于区间提示“提高”。
@MainActor
final class WatchHapticPlayer: HapticPlaying {
    func play(_ kind: ZoneHapticKind) {
        switch kind {
        case .aboveZone:
            WKInterfaceDevice.current().play(.directionDown)
        case .belowZone:
            WKInterfaceDevice.current().play(.directionUp)
        }
    }
}
