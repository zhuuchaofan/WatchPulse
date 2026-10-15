import Foundation
import WatchPulseShared

/// 由 GPS 定位样本得到实时速度（纯逻辑，可在 Linux 上测试）。
///
/// - 只采用有效样本：`speed`、`speedAccuracy` 非负，水平 / 速度精度在阈值内，时间递增，不过旧；
/// - 过滤跳点：超过合理上限的速度，以及相对上一个采用样本加速度过大的样本；连续多次“跳点”
///   说明速度确实变化了，此时接受并重新开始平滑；
/// - 平滑：最近 `smoothingWindow` 秒内采用样本的平均值；
/// - 超过 `staleAfter` 秒没有新样本 → `.stale`，不带数值（界面显示 `--`，不当作 0）；
/// - 暂停期间不采用样本，继续后重新开始。
///
/// 所有阈值集中在 `Configuration`，均为初始值，**需要真机骑行校准**。
public struct GPSSpeedCalculator: Sendable {
    public struct Configuration: Sendable {
        /// 水平精度超过此值（米）的样本不采用。
        public var maximumHorizontalAccuracy: Double
        /// 水平精度超过此值（米）时标记为“精度低”。
        public var lowAccuracyHorizontal: Double
        /// 速度精度超过此值（米 / 秒）的样本不采用。
        public var maximumSpeedAccuracy: Double
        /// 速度精度超过此值（米 / 秒）时标记为“精度低”。
        public var lowAccuracySpeed: Double
        /// 骑行速度合理上限（米 / 秒）。30 m/s = 108 km/h。
        public var maximumPlausibleSpeed: Double
        /// 相邻采用样本之间允许的最大加速度（米 / 秒²）。
        public var maximumAcceleration: Double
        /// 连续多少次被判为跳点后接受新速度。
        public var spikeResetCount: Int
        /// 平滑窗口（秒）。
        public var smoothingWindow: TimeInterval
        /// 多久没有新样本视为过期（秒）。
        public var staleAfter: TimeInterval
        /// 收到时已超过此时长（秒）的样本不采用（系统缓存的旧定位）。
        public var maximumFixAge: TimeInterval

        public init(
            maximumHorizontalAccuracy: Double = 50,
            lowAccuracyHorizontal: Double = 15,
            maximumSpeedAccuracy: Double = 5,
            lowAccuracySpeed: Double = 2,
            maximumPlausibleSpeed: Double = 30,
            maximumAcceleration: Double = 4,
            spikeResetCount: Int = 3,
            smoothingWindow: TimeInterval = 5,
            staleAfter: TimeInterval = 5,
            maximumFixAge: TimeInterval = 10
        ) {
            self.maximumHorizontalAccuracy = maximumHorizontalAccuracy
            self.lowAccuracyHorizontal = lowAccuracyHorizontal
            self.maximumSpeedAccuracy = maximumSpeedAccuracy
            self.lowAccuracySpeed = lowAccuracySpeed
            self.maximumPlausibleSpeed = maximumPlausibleSpeed
            self.maximumAcceleration = maximumAcceleration
            self.spikeResetCount = spikeResetCount
            self.smoothingWindow = smoothingWindow
            self.staleAfter = staleAfter
            self.maximumFixAge = maximumFixAge
        }
    }

    public enum RejectionReason: Hashable, Sendable {
        case paused
        case invalidSpeed
        case poorAccuracy
        case tooOld
        case outOfOrder
        case implausibleSpeed
        case spike
    }

    public enum IngestResult: Hashable, Sendable {
        case accepted
        case rejected(RejectionReason)
    }

    private struct Accepted: Sendable {
        let timestamp: Date
        let speed: Double
        let isLowAccuracy: Bool
    }

    public let configuration: Configuration
    public var authorization: LocationAuthorization = .notDetermined
    public private(set) var isPaused = false
    private var window: [Accepted] = []
    private var consecutiveSpikes = 0

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    @discardableResult
    public mutating func ingest(_ fix: LocationFix, receivedAt now: Date) -> IngestResult {
        guard !isPaused else { return .rejected(.paused) }
        guard fix.speed.isFinite, fix.speed >= 0, fix.speedAccuracy.isFinite, fix.speedAccuracy >= 0 else {
            return .rejected(.invalidSpeed)
        }
        guard fix.horizontalAccuracy.isFinite, fix.horizontalAccuracy >= 0,
              fix.horizontalAccuracy <= configuration.maximumHorizontalAccuracy,
              fix.speedAccuracy <= configuration.maximumSpeedAccuracy else {
            return .rejected(.poorAccuracy)
        }
        guard now.timeIntervalSince(fix.timestamp) <= configuration.maximumFixAge else {
            return .rejected(.tooOld)
        }
        if let last = window.last, fix.timestamp <= last.timestamp {
            return .rejected(.outOfOrder)
        }
        guard fix.speed <= configuration.maximumPlausibleSpeed else {
            return .rejected(.implausibleSpeed)
        }
        if let last = window.last {
            let interval = fix.timestamp.timeIntervalSince(last.timestamp)
            let acceleration = abs(fix.speed - last.speed) / interval
            if acceleration > configuration.maximumAcceleration {
                consecutiveSpikes += 1
                guard consecutiveSpikes >= configuration.spikeResetCount else {
                    return .rejected(.spike)
                }
                // 持续的“跳点”是真实变化：丢弃旧窗口，从新速度重新平滑。
                window.removeAll()
            }
        }
        consecutiveSpikes = 0
        let isLowAccuracy = fix.horizontalAccuracy > configuration.lowAccuracyHorizontal
            || fix.speedAccuracy > configuration.lowAccuracySpeed
        window.append(Accepted(timestamp: fix.timestamp, speed: fix.speed, isLowAccuracy: isLowAccuracy))
        let cutoff = fix.timestamp.addingTimeInterval(-configuration.smoothingWindow)
        window.removeAll { $0.timestamp < cutoff }
        return .accepted
    }

    /// `now` 时刻的速度读数。
    public func sample(at now: Date) -> WorkoutSpeedSample {
        if authorization == .denied {
            return .unavailable(.notAuthorized)
        }
        if isPaused {
            return .unavailable(.paused, source: .gps, sampleDate: window.last?.timestamp)
        }
        guard let last = window.last else {
            return .unavailable(.unavailable)
        }
        guard now.timeIntervalSince(last.timestamp) <= configuration.staleAfter else {
            return .unavailable(.stale, source: .gps, sampleDate: last.timestamp)
        }
        let average = window.map(\.speed).reduce(0, +) / Double(window.count)
        let quality: SpeedQuality = window.contains { $0.isLowAccuracy } ? .lowAccuracy : .good
        return WorkoutSpeedSample(metersPerSecond: average, sampleDate: last.timestamp, source: .gps, quality: quality)
    }

    public mutating func pause() {
        isPaused = true
    }

    /// 继续运动：暂停前的样本不参与平滑，也不作为跳点判断的参照。
    public mutating func resume() {
        isPaused = false
        reset()
    }

    public mutating func reset() {
        window.removeAll()
        consecutiveSpikes = 0
    }
}
