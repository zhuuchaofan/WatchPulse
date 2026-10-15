import Foundation

/// 睡眠阶段，对应 `HKCategoryValueSleepAnalysis`。
public enum SleepStage: String, CaseIterable, Codable, Sendable {
    case inBed
    case awake
    case asleepUnspecified
    case core
    case deep
    case rem

    public var isAsleep: Bool {
        switch self {
        case .asleepUnspecified, .core, .deep, .rem: return true
        case .inBed, .awake: return false
        }
    }

    public var title: String {
        switch self {
        case .inBed: return "卧床"
        case .awake: return "清醒"
        case .asleepUnspecified: return "睡眠"
        case .core: return "核心睡眠"
        case .deep: return "深度睡眠"
        case .rem: return "快速动眼"
        }
    }

    /// 多个来源重叠时的优先级：越大越优先。
    var priority: Int {
        switch self {
        case .deep: return 6
        case .rem: return 5
        case .core: return 4
        case .asleepUnspecified: return 3
        case .awake: return 2
        case .inBed: return 1
        }
    }
}

/// 一段睡眠记录（一条 `HKCategorySample`）。
public struct SleepSegment: Hashable, Codable, Sendable {
    public let start: Date
    public let end: Date
    public let stage: SleepStage
    public let sourceName: String?

    public init(start: Date, end: Date, stage: SleepStage, sourceName: String? = nil) {
        self.start = start
        self.end = end
        self.stage = stage
        self.sourceName = sourceName
    }
}

/// 一晚的睡眠汇总。
public struct SleepNight: Hashable, Codable, Sendable, Identifiable {
    /// 该夜归属的日期（醒来那天的零点）。
    public let date: Date
    public let start: Date
    public let end: Date
    /// 实际睡着的时长（去重后）。
    public let asleepDuration: TimeInterval
    /// 卧床时长（所有记录的并集）。
    public let inBedDuration: TimeInterval
    public let awakeDuration: TimeInterval
    /// 各睡眠阶段时长（仅含睡着的阶段与清醒）。
    public let stageDurations: [SleepStage: TimeInterval]
    public let sourceNames: [String]

    public var id: Date { date }

    /// 只有卧床记录（例如只来自 iPhone 睡眠计划）而没有睡着记录。
    public var isInBedOnly: Bool { asleepDuration == 0 && inBedDuration > 0 }

    /// 展示用时长：有睡着记录用睡着时长，否则用卧床时长。
    public var primaryDuration: TimeInterval { isInBedOnly ? inBedDuration : asleepDuration }

    public init(
        date: Date,
        start: Date,
        end: Date,
        asleepDuration: TimeInterval,
        inBedDuration: TimeInterval,
        awakeDuration: TimeInterval,
        stageDurations: [SleepStage: TimeInterval],
        sourceNames: [String]
    ) {
        self.date = date
        self.start = start
        self.end = end
        self.asleepDuration = asleepDuration
        self.inBedDuration = inBedDuration
        self.awakeDuration = awakeDuration
        self.stageDurations = stageDurations
        self.sourceNames = sourceNames
    }
}

/// 把零散的睡眠记录按夜聚合。
///
/// - 夜的归属：以 18:00 为分界，开始于 D-1 日 18:00 至 D 日 18:00 之间的记录属于 D 日这一夜；
/// - 多个来源（iPhone、Apple Watch、第三方 App）时间重叠时不重复累计：
///   按时间轴扫描，每一小段只计入优先级最高的阶段（深睡 > REM > 核心 > 未细分 > 清醒 > 卧床）。
public enum SleepAggregator {
    public static func nights(from segments: [SleepSegment], calendar: Calendar = .current) -> [SleepNight] {
        let valid = segments.filter { $0.end > $0.start }
        let grouped = Dictionary(grouping: valid) { nightDate(for: $0, calendar: calendar) }
        return grouped
            .map { date, segments in summarize(date: date, segments: segments) }
            .sorted { $0.date < $1.date }
    }

    public static func nightDate(for segment: SleepSegment, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: segment.start.addingTimeInterval(6 * 3600))
    }

    static func summarize(date: Date, segments: [SleepSegment]) -> SleepNight {
        let boundaries = Array(Set(segments.flatMap { [$0.start, $0.end] })).sorted()
        var asleep: TimeInterval = 0
        var awake: TimeInterval = 0
        var inBed: TimeInterval = 0
        var stages: [SleepStage: TimeInterval] = [:]

        for (lower, upper) in zip(boundaries, boundaries.dropFirst()) {
            let covering = segments.filter { $0.start <= lower && $0.end >= upper }
            guard let best = covering.max(by: { $0.stage.priority < $1.stage.priority })?.stage else {
                continue
            }
            let duration = upper.timeIntervalSince(lower)
            inBed += duration
            if best.isAsleep {
                asleep += duration
                stages[best, default: 0] += duration
            } else if best == .awake {
                awake += duration
                stages[.awake, default: 0] += duration
            }
        }

        let sources = Array(Set(segments.compactMap(\.sourceName))).sorted()
        return SleepNight(
            date: date,
            start: segments.map(\.start).min()!,
            end: segments.map(\.end).max()!,
            asleepDuration: asleep,
            inBedDuration: inBed,
            awakeDuration: awake,
            stageDurations: stages,
            sourceNames: sources
        )
    }
}
