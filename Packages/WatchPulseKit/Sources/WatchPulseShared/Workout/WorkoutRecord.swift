import Foundation

/// 一次已完成的运动（对应 `HKWorkout`）。
public struct WorkoutRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let activity: WorkoutActivityKind
    public let location: WorkoutLocation
    public let startDate: Date
    public let endDate: Date
    /// 实际运动时长（不含暂停），秒。
    public let duration: TimeInterval
    public let activeEnergyKilocalories: Double?
    public let distanceMeters: Double?
    public let averageHeartRate: Double?
    public let maximumHeartRate: Double?
    public let minimumHeartRate: Double?
    public let sourceName: String

    public init(
        id: UUID,
        activity: WorkoutActivityKind,
        location: WorkoutLocation,
        startDate: Date,
        endDate: Date,
        duration: TimeInterval,
        activeEnergyKilocalories: Double? = nil,
        distanceMeters: Double? = nil,
        averageHeartRate: Double? = nil,
        maximumHeartRate: Double? = nil,
        minimumHeartRate: Double? = nil,
        sourceName: String
    ) {
        self.id = id
        self.activity = activity
        self.location = location
        self.startDate = startDate
        self.endDate = endDate
        self.duration = duration
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.distanceMeters = distanceMeters
        self.averageHeartRate = averageHeartRate
        self.maximumHeartRate = maximumHeartRate
        self.minimumHeartRate = minimumHeartRate
        self.sourceName = sourceName
    }
}

/// 心率曲线上的一个点。
public struct HeartRatePoint: Identifiable, Hashable, Codable, Sendable {
    public let date: Date
    public let beatsPerMinute: Double

    public var id: Date { date }

    public init(date: Date, beatsPerMinute: Double) {
        self.date = date
        self.beatsPerMinute = beatsPerMinute
    }
}

/// 心率曲线统计。
public struct HeartRateSeriesStatistics: Hashable, Codable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let average: Double

    public init?(points: [HeartRatePoint]) {
        guard !points.isEmpty else { return nil }
        let values = points.map(\.beatsPerMinute)
        minimum = values.min()!
        maximum = values.max()!
        average = values.reduce(0, +) / Double(values.count)
    }
}

public enum HeartRateSeries {
    /// 把心率点按时间等分为不超过 `maxPoints` 个桶，每桶取平均，便于绘图。
    ///
    /// 输入不要求有序；输出按时间升序。点数不超过上限时只排序不降采样。
    public static func downsample(_ points: [HeartRatePoint], maxPoints: Int) -> [HeartRatePoint] {
        let sorted = points.sorted { $0.date < $1.date }
        guard maxPoints > 0, sorted.count > maxPoints,
              let first = sorted.first?.date, let last = sorted.last?.date, last > first else {
            return sorted
        }
        let span = last.timeIntervalSince(first)
        let bucketWidth = span / Double(maxPoints)
        var sums = [Double](repeating: 0, count: maxPoints)
        var times = [Double](repeating: 0, count: maxPoints)
        var counts = [Int](repeating: 0, count: maxPoints)
        for point in sorted {
            let offset = point.date.timeIntervalSince(first)
            let index = min(maxPoints - 1, Int(offset / bucketWidth))
            sums[index] += point.beatsPerMinute
            times[index] += offset
            counts[index] += 1
        }
        return (0..<maxPoints).compactMap { index in
            guard counts[index] > 0 else { return nil }
            let count = Double(counts[index])
            return HeartRatePoint(
                date: first.addingTimeInterval(times[index] / count),
                beatsPerMinute: sums[index] / count
            )
        }
    }
}
