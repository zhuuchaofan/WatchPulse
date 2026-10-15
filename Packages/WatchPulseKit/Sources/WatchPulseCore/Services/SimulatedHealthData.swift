import Foundation
import WatchPulseShared

/// 确定性的伪随机数生成器（SplitMix64），保证模拟数据可复现、测试稳定。
public struct SeededRandomGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// [range.lowerBound, range.upperBound] 内的随机数。
    public mutating func value(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}

/// 演示模式与 Preview 用的模拟健康数据。**不是真实健康数据**，来源统一标注为 `sourceName`。
public struct SimulatedHealthData: Sendable {
    public static let sourceName = "模拟数据（非真实）"

    public let now: Date
    public let calendar: Calendar

    public init(now: Date, calendar: Calendar = .current) {
        self.now = now
        self.calendar = calendar
    }

    public var latestHeartRate: HeartRateSample {
        let date = now.addingTimeInterval(-8 * 60)
        return HeartRateSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!,
            beatsPerMinute: 68,
            startDate: date,
            endDate: date,
            source: HealthSampleSource(
                name: Self.sourceName,
                bundleIdentifier: "watchpulse.simulated",
                productType: nil,
                deviceName: "Simulated Watch",
                deviceModel: "Simulator"
            )
        )
    }

    public func summary(for kind: HealthMetricKind) -> MetricSummaryValue {
        let today = calendar.startOfDay(for: now)
        switch kind {
        case .heartRate:
            return MetricSummaryValue(kind: kind, value: 68, date: latestHeartRate.endDate, sourceName: Self.sourceName)
        case .heartRateVariability:
            return MetricSummaryValue(kind: kind, value: 46, date: now.addingTimeInterval(-3 * 3600), sourceName: Self.sourceName)
        case .restingHeartRate:
            return MetricSummaryValue(kind: kind, value: 57, date: today, sourceName: Self.sourceName)
        case .stepCount:
            return MetricSummaryValue(kind: kind, value: 6_482, date: today, sourceName: Self.sourceName)
        case .activeEnergy:
            return MetricSummaryValue(kind: kind, value: 312, date: today, sourceName: Self.sourceName)
        case .sleep:
            let night = sleepNight(for: today)
            return MetricSummaryValue(
                kind: kind,
                value: night.primaryDuration / 3600,
                date: night.end,
                sourceName: Self.sourceName,
                sleepNight: night
            )
        }
    }

    /// 截至今天的 `days` 天每日数据。
    public func trend(for kind: HealthMetricKind, days: Int) -> [MetricDataPoint] {
        var generator = SeededRandomGenerator(seed: UInt64(abs(kind.rawValue.hashValueStable)))
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { offset -> MetricDataPoint? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let weekday = calendar.component(.weekday, from: day)
            let isWeekend = weekday == 1 || weekday == 7
            switch kind {
            case .heartRate:
                let average = generator.value(in: 66...78)
                return MetricDataPoint(date: day, value: average, minimum: average - generator.value(in: 12...18), maximum: average + generator.value(in: 40...70))
            case .heartRateVariability:
                let average = generator.value(in: 35...58)
                return MetricDataPoint(date: day, value: average, minimum: average - 10, maximum: average + 15)
            case .restingHeartRate:
                let value = generator.value(in: 54...61)
                return MetricDataPoint(date: day, value: value, minimum: value, maximum: value)
            case .stepCount:
                let base = isWeekend ? 9_000.0 : 6_500.0
                return MetricDataPoint(date: day, value: (base + generator.value(in: -2_500...3_500)).rounded())
            case .activeEnergy:
                return MetricDataPoint(date: day, value: (isWeekend ? 420 : 320) + generator.value(in: -90...140))
            case .sleep:
                return MetricDataPoint(date: day, value: generator.value(in: 5.8...8.4))
            }
        }
    }

    /// 截至今天（含）的 `days` 夜睡眠（确定性模拟数据；入睡 / 醒来时间每晚略有不同）。
    public func sleepNights(days: Int) -> [SleepNight] {
        let today = calendar.startOfDay(for: now)
        let offsets = [0, 15, -10, 25, 5, -20, 10]
        return (0..<days).reversed().compactMap { offset -> SleepNight? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return sleepNight(for: day, shiftMinutes: offsets[offset % offsets.count])
        }
    }

    /// 某天醒来的那一夜（23:20 入睡，次日 06:50 醒来，含分期）。
    public func sleepNight(for day: Date, shiftMinutes: Int = 0) -> SleepNight {
        let wake = calendar.date(byAdding: .minute, value: 6 * 60 + 50 + shiftMinutes, to: day)!
        let bedtime = calendar.date(byAdding: .minute, value: -40 + shiftMinutes, to: day)!
        func at(_ minutes: Int) -> Date { bedtime.addingTimeInterval(TimeInterval(minutes * 60)) }
        let segments = [
            SleepSegment(start: bedtime, end: wake, stage: .inBed, sourceName: Self.sourceName),
            SleepSegment(start: at(10), end: at(95), stage: .core, sourceName: Self.sourceName),
            SleepSegment(start: at(95), end: at(160), stage: .deep, sourceName: Self.sourceName),
            SleepSegment(start: at(160), end: at(185), stage: .rem, sourceName: Self.sourceName),
            SleepSegment(start: at(185), end: at(195), stage: .awake, sourceName: Self.sourceName),
            SleepSegment(start: at(195), end: at(330), stage: .core, sourceName: Self.sourceName),
            SleepSegment(start: at(330), end: at(380), stage: .rem, sourceName: Self.sourceName),
            SleepSegment(start: at(380), end: at(440), stage: .core, sourceName: Self.sourceName),
        ]
        return SleepAggregator.nights(from: segments, calendar: calendar).first!
    }
}

private extension String {
    /// 与进程无关的稳定哈希（`hashValue` 每次启动都会变化）。
    var hashValueStable: Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return Int(truncatingIfNeeded: hash >> 1)
    }
}
