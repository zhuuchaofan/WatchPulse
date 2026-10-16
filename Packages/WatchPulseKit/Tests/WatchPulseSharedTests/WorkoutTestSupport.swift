import Foundation
import WatchPulseShared

/// 测试用的运动记录构造器（固定基准时间，避免依赖当前时间）。
enum Fixture {
    /// 2026-03-01 10:00:00 UTC（周日）。
    static let base = Date(timeIntervalSince1970: 1_772_359_200)

    static let watch = WorkoutSourceInfo(
        name: "体能训练",
        bundleIdentifier: "com.apple.health.ABCD",
        deviceName: "Apple Watch",
        deviceModel: "Watch",
        deviceHardwareVersion: "Watch6,1"
    )

    static let thirdParty = WorkoutSourceInfo(
        name: "Strava",
        bundleIdentifier: "com.strava.stravaride",
        deviceName: nil,
        deviceModel: nil,
        deviceHardwareVersion: nil
    )

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static func workout(
        _ n: Int,
        activity: WorkoutActivityKind = .cycling,
        location: WorkoutLocation = .outdoor,
        start: TimeInterval = 0,
        minutes: Double = 60,
        distanceKm: Double? = 20,
        average: Double? = 140,
        source: WorkoutSourceInfo = Fixture.watch
    ) -> WorkoutRecord {
        let startDate = base.addingTimeInterval(start)
        let duration = minutes * 60
        return WorkoutRecord(
            id: uuid(n),
            activity: activity,
            location: location,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(duration),
            duration: duration,
            activeEnergyKilocalories: 400,
            distanceMeters: distanceKm.map { $0 * 1000 },
            averageHeartRate: average,
            maximumHeartRate: average.map { $0 + 25 },
            minimumHeartRate: average.map { $0 - 30 },
            sourceName: source.name,
            sourceInfo: source
        )
    }

    /// 每 `interval` 秒一个样本的心率曲线。
    static func heartRate(
        for workout: WorkoutRecord,
        interval: TimeInterval = 5,
        bpm: Double = 140,
        from: TimeInterval = 0,
        to: TimeInterval? = nil
    ) -> [HeartRatePoint] {
        let end = to ?? workout.endDate.timeIntervalSince(workout.startDate)
        return stride(from: from, through: end, by: interval).map {
            HeartRatePoint(date: workout.startDate.addingTimeInterval($0), beatsPerMinute: bpm)
        }
    }
}
