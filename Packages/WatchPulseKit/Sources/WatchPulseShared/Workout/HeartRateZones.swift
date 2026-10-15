import Foundation

/// 训练心率区间 Z1–Z5。仅作训练参考，不是医学诊断。
public enum TrainingZone: Int, CaseIterable, Codable, Comparable, Sendable, Identifiable {
    case z1 = 1
    case z2
    case z3
    case z4
    case z5

    public var id: Int { rawValue }

    public var title: String { "Z\(rawValue)" }

    public var name: String {
        switch self {
        case .z1: return "热身"
        case .z2: return "燃脂"
        case .z3: return "有氧"
        case .z4: return "乳酸阈"
        case .z5: return "无氧"
        }
    }

    public static func < (lhs: TrainingZone, rhs: TrainingZone) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 用户设置的个人心率区间。
///
/// - 只能由用户输入最大心率（或直接输入各区间下限）得到，**不使用** 220−年龄 之类的公式冒充真实最大心率；
/// - 5 个下限严格递增且都小于最大心率：Z1 = [下限1, 下限2)，…，Z5 = [下限5, 最大心率]；
/// - 低于 Z1 下限时不属于任何区间（`zone(for:)` 返回 `nil`），高于最大心率仍按 Z5。
public struct HeartRateZoneSettings: Hashable, Codable, Sendable {
    public enum Method: String, Hashable, Codable, Sendable {
        /// 按最大心率的百分比生成（默认 50 / 60 / 70 / 80 / 90%）。
        case percentOfMaximum
        /// 用户逐个输入区间下限。
        case custom
    }

    public enum ValidationError: Error, Hashable, Sendable, LocalizedError {
        case maximumOutOfRange
        case wrongBoundaryCount
        case boundariesNotIncreasing
        case boundaryOutOfRange

        public var errorDescription: String? {
            switch self {
            case .maximumOutOfRange: return "最大心率需在 \(HeartRateZoneSettings.maximumRange.lowerBound)–\(HeartRateZoneSettings.maximumRange.upperBound) 次/分之间"
            case .wrongBoundaryCount: return "需要 5 个区间下限"
            case .boundariesNotIncreasing: return "区间下限必须逐级升高、不能重叠"
            case .boundaryOutOfRange: return "区间下限需不低于 \(HeartRateZoneSettings.minimumBoundary) 次/分且低于最大心率"
            }
        }
    }

    public static let maximumRange = 100...230
    public static let minimumBoundary = 40
    public static let defaultPercentages: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9]

    public let method: Method
    public let maximumHeartRate: Int
    /// Z1…Z5 的下限（次/分）。
    public let lowerBounds: [Int]

    /// 按最大心率百分比生成区间。
    public static func percentOfMaximum(_ maximumHeartRate: Int) throws -> HeartRateZoneSettings {
        let bounds = defaultPercentages.map { Int((Double(maximumHeartRate) * $0).rounded()) }
        return try HeartRateZoneSettings(method: .percentOfMaximum, maximumHeartRate: maximumHeartRate, lowerBounds: bounds)
    }

    public init(method: Method, maximumHeartRate: Int, lowerBounds: [Int]) throws {
        try Self.validate(maximumHeartRate: maximumHeartRate, lowerBounds: lowerBounds)
        self.method = method
        self.maximumHeartRate = maximumHeartRate
        self.lowerBounds = lowerBounds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let method = try container.decode(Method.self, forKey: .method)
        let maximum = try container.decode(Int.self, forKey: .maximumHeartRate)
        let bounds = try container.decode([Int].self, forKey: .lowerBounds)
        // 存储或对端传来的数据也必须合法，否则视为解码失败。
        try self.init(method: method, maximumHeartRate: maximum, lowerBounds: bounds)
    }

    public static func validate(maximumHeartRate: Int, lowerBounds: [Int]) throws {
        guard maximumRange.contains(maximumHeartRate) else { throw ValidationError.maximumOutOfRange }
        guard lowerBounds.count == TrainingZone.allCases.count else { throw ValidationError.wrongBoundaryCount }
        guard zip(lowerBounds, lowerBounds.dropFirst()).allSatisfy({ $0 < $1 }) else {
            throw ValidationError.boundariesNotIncreasing
        }
        guard lowerBounds.allSatisfy({ $0 >= minimumBoundary && $0 < maximumHeartRate }) else {
            throw ValidationError.boundaryOutOfRange
        }
    }

    /// 心率所在区间；低于 Z1 下限返回 `nil`。
    public func zone(for beatsPerMinute: Double) -> TrainingZone? {
        guard beatsPerMinute.isFinite else { return nil }
        for zone in TrainingZone.allCases.reversed() where beatsPerMinute >= Double(lowerBound(of: zone)) {
            return zone
        }
        return nil
    }

    public func lowerBound(of zone: TrainingZone) -> Int {
        lowerBounds[zone.rawValue - 1]
    }

    /// 区间的上限（含）。Z5 的上限为最大心率。
    public func upperBound(of zone: TrainingZone) -> Int {
        zone == .z5 ? maximumHeartRate : lowerBounds[zone.rawValue] - 1
    }

    public func range(of zone: TrainingZone) -> ClosedRange<Int> {
        lowerBound(of: zone)...upperBound(of: zone)
    }
}

/// Watch 端目标区间震动提醒的设置。默认关闭；只有设置了心率区间才能开启。
public struct ZoneAlertSettings: Hashable, Codable, Sendable {
    public var isEnabled: Bool
    public var targetZone: TrainingZone
    /// 持续越界多久才提醒（秒）。
    public var sustainDuration: TimeInterval
    /// 同时要求的最少连续越界样本数。
    public var minimumConsecutiveSamples: Int
    /// 两次提醒的最短间隔（秒）。
    public var cooldown: TimeInterval
    /// 提醒后需回到区间内至少这么多次/分（滞回），才允许下一次提醒。
    public var hysteresisBPM: Double
    /// 心率样本超过这个时间未更新视为过期，不提醒（秒）。
    public var maximumSampleAge: TimeInterval

    public init(
        isEnabled: Bool = false,
        targetZone: TrainingZone = .z2,
        sustainDuration: TimeInterval = 10,
        minimumConsecutiveSamples: Int = 3,
        cooldown: TimeInterval = 60,
        hysteresisBPM: Double = 3,
        maximumSampleAge: TimeInterval = 10
    ) {
        self.isEnabled = isEnabled
        self.targetZone = targetZone
        self.sustainDuration = sustainDuration
        self.minimumConsecutiveSamples = minimumConsecutiveSamples
        self.cooldown = cooldown
        self.hysteresisBPM = hysteresisBPM
        self.maximumSampleAge = maximumSampleAge
    }
}
