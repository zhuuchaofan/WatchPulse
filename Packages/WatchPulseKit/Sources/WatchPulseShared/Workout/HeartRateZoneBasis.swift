import Foundation

/// 心率区间分析所用的口径。保存或展示区间分布时必须一并标注。
///
/// 仓库里有两种口径，不得混用：
/// - **个人训练区间**（`TrainingZone` + `HeartRateZoneSettings`）：用户输入并确认的最大心率 / 区间下限。
///   Watch 实时提醒、iPhone 码表与历史进步分析使用它；两次分析配置相同才可比较。
/// - **本次相对区间**（`HeartRateZone`）：以本次运动观测到的最高心率为参照，仅用于单次运动详情展示，不可跨运动比较。
///
/// 不使用 220−年龄 等公式推算最大心率。
public struct HeartRateZoneBasis: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case personal
        case sessionRelative
    }

    public enum MaximumSource: String, Hashable, Codable, Sendable {
        /// 用户输入（或确认）。
        case userEntered
        /// 本次运动中观测到的最高值，不是真实最大心率。
        case observedInWorkout
    }

    public let kind: Kind
    public let maximumHeartRate: Int
    public let maximumSource: MaximumSource
    /// 个人区间 Z1…Z5 的下限；相对区间为 `nil`。
    public let lowerBounds: [Int]?

    public init(kind: Kind, maximumHeartRate: Int, maximumSource: MaximumSource, lowerBounds: [Int]?) {
        self.kind = kind
        self.maximumHeartRate = maximumHeartRate
        self.maximumSource = maximumSource
        self.lowerBounds = lowerBounds
    }

    public static func personal(_ settings: HeartRateZoneSettings) -> HeartRateZoneBasis {
        HeartRateZoneBasis(
            kind: .personal,
            maximumHeartRate: settings.maximumHeartRate,
            maximumSource: .userEntered,
            lowerBounds: settings.lowerBounds
        )
    }

    public static func sessionRelative(observedMaximum: Double) -> HeartRateZoneBasis {
        HeartRateZoneBasis(
            kind: .sessionRelative,
            maximumHeartRate: Int(observedMaximum.rounded()),
            maximumSource: .observedInWorkout,
            lowerBounds: nil
        )
    }

    /// 最大心率是否由用户确认（而非观测值 / 推算值）。
    public var isUserConfirmedMaximum: Bool { maximumSource == .userEntered }

    /// 两个口径下的区间分布是否可以相互比较：必须都是个人区间，且区间边界与最大心率完全一致。
    public func isComparable(with other: HeartRateZoneBasis) -> Bool {
        kind == .personal && other.kind == .personal
            && maximumHeartRate == other.maximumHeartRate
            && lowerBounds == other.lowerBounds
    }

    public var title: String {
        switch kind {
        case .personal: return "个人心率区间（最大心率 \(maximumHeartRate) 次/分，来源：用户输入）"
        case .sessionRelative: return "本次相对区间（本次最高心率 \(maximumHeartRate) 次/分）"
        }
    }
}

/// 某次运动在特定口径下的区间分布。
public struct HeartRateZoneDistribution: Hashable, Codable, Sendable {
    public let basis: HeartRateZoneBasis
    /// 区间编号（1…5，含义由 `basis.kind` 决定）→ 累计秒数。
    public let durations: [Int: TimeInterval]
    /// 低于个人 Z1 下限的时长（相对区间恒为 0）。
    public let belowRangeDuration: TimeInterval
    /// 参与分布的总时长（排除缺测）。
    public let coveredDuration: TimeInterval

    public init(basis: HeartRateZoneBasis, durations: [Int: TimeInterval], belowRangeDuration: TimeInterval, coveredDuration: TimeInterval) {
        self.basis = basis
        self.durations = durations
        self.belowRangeDuration = belowRangeDuration
        self.coveredDuration = coveredDuration
    }
}

public enum HeartRateZoneAnalyzer {
    /// 以用户个人区间统计区间时长。相邻样本之间的时长计入前一个样本的区间，超过 `maximumGap` 视为缺测。
    public static func personal(
        points: [HeartRatePoint],
        settings: HeartRateZoneSettings,
        maximumGap: TimeInterval = 60
    ) -> HeartRateZoneDistribution {
        let sorted = points.sorted { $0.date < $1.date }
        var durations: [Int: TimeInterval] = [:]
        var below: TimeInterval = 0
        var covered: TimeInterval = 0
        for (current, next) in zip(sorted, sorted.dropFirst()) {
            let gap = next.date.timeIntervalSince(current.date)
            guard gap > 0, gap <= maximumGap else { continue }
            covered += gap
            if let zone = settings.zone(for: current.beatsPerMinute) {
                durations[zone.rawValue, default: 0] += gap
            } else {
                below += gap
            }
        }
        return HeartRateZoneDistribution(
            basis: .personal(settings), durations: durations, belowRangeDuration: below, coveredDuration: covered
        )
    }
}
