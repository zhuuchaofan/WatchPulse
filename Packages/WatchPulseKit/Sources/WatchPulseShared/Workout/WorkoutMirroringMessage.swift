import Foundation

/// iPhone 发给 Watch 的远程控制命令。
public enum WorkoutRemoteCommand: String, Codable, Sendable {
    case pause
    case resume
    case end

    public var title: String {
        switch self {
        case .pause: return "暂停"
        case .resume: return "继续"
        case .end: return "结束"
        }
    }
}

/// 运动会话的完整状态。用于连接建立、断线恢复后让 iPhone 一次性追上 Watch 的状态。
public struct WorkoutStateSnapshot: Hashable, Codable, Sendable {
    public let configuration: WorkoutConfigurationRequest?
    public let phase: WorkoutSessionPhase
    public let startDate: Date?
    public let metrics: WorkoutMetricsSnapshot?

    public init(
        configuration: WorkoutConfigurationRequest?,
        phase: WorkoutSessionPhase,
        startDate: Date?,
        metrics: WorkoutMetricsSnapshot?
    ) {
        self.configuration = configuration
        self.phase = phase
        self.startDate = startDate
        self.metrics = metrics
    }
}

/// 主会话（Watch）与镜像会话（iPhone）之间交换的消息。
///
/// 序列化后的 `Data` 通过 `HKWorkoutSession.sendToRemoteWorkoutSession(data:)` 发送，
/// 对端在 `HKWorkoutSessionDelegate.workoutSession(_:didReceiveDataFromRemoteWorkoutSession:)` 中
/// 用 `WorkoutMirroringCodec.decode(_:)` 解码。
public enum WorkoutMirroringMessage: Hashable, Codable, Sendable {
    /// Watch → iPhone：会话阶段变化。
    case phaseChanged(WorkoutSessionPhase, at: Date)
    /// Watch → iPhone：最新运动指标。
    case metrics(WorkoutMetricsSnapshot)
    /// Watch → iPhone：完整状态（连接建立 / 恢复 / 应 iPhone 请求）。
    case stateSync(WorkoutStateSnapshot)
    /// Watch → iPhone：心跳（暂停期间没有指标时用于判断连接是否存活）。
    case heartbeat(at: Date)
    /// Watch → iPhone：命令无法执行。
    case commandRejected(WorkoutRemoteCommand, reason: String)
    /// iPhone → Watch：控制命令。
    case command(WorkoutRemoteCommand)
    /// iPhone → Watch：请求完整状态。
    case requestStateSync
}

/// 消息信封：带会话 ID 与递增序号，接收端据此丢弃乱序 / 过期消息，并识别 Watch 端会话重建。
public struct WorkoutMirroringEnvelope: Hashable, Codable, Sendable {
    public let version: Int
    public let sessionID: UUID
    public let sequence: UInt64
    public let sentAt: Date
    public let message: WorkoutMirroringMessage

    public init(
        version: Int = WorkoutMirroringCodec.currentVersion,
        sessionID: UUID,
        sequence: UInt64,
        sentAt: Date,
        message: WorkoutMirroringMessage
    ) {
        self.version = version
        self.sessionID = sessionID
        self.sequence = sequence
        self.sentAt = sentAt
        self.message = message
    }
}

/// 镜像消息的编解码器。外层带版本号，便于两端 App 版本不一致时安全拒绝。
public enum WorkoutMirroringCodec {
    public static let currentVersion = 1

    /// `sendToRemoteWorkoutSession` 单条数据不宜过大，超过此大小视为异常。
    public static let maximumPayloadSize = 64 * 1024

    public enum CodecError: Error, Equatable, Sendable {
        case unsupportedVersion(Int)
        case malformedPayload
        case payloadTooLarge(Int)
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    public static func encode(_ envelope: WorkoutMirroringEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(envelope)
        guard data.count <= maximumPayloadSize else {
            throw CodecError.payloadTooLarge(data.count)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> WorkoutMirroringEnvelope {
        guard data.count <= maximumPayloadSize else {
            throw CodecError.payloadTooLarge(data.count)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let probe: VersionProbe
        do {
            probe = try decoder.decode(VersionProbe.self, from: data)
        } catch {
            throw CodecError.malformedPayload
        }
        guard probe.version == currentVersion else {
            throw CodecError.unsupportedVersion(probe.version)
        }
        do {
            return try decoder.decode(WorkoutMirroringEnvelope.self, from: data)
        } catch {
            throw CodecError.malformedPayload
        }
    }
}
