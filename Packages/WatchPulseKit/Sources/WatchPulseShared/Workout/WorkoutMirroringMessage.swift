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

/// 运动记录的保存状态。“运动结束”与“保存成功”是两件事，iPhone 只有收到 `.saved` 才能显示已保存。
public enum WorkoutSaveStatus: Hashable, Codable, Sendable {
    /// 运动尚未结束。
    case pending
    /// 已停止，正在写入 HealthKit。
    case saving
    /// HealthKit 返回了保存后的运动。
    case saved(workoutID: UUID?)
    case failed(reason: String)

    public var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }
}

/// 运动会话的完整状态。用于连接建立、断线恢复后让 iPhone 一次性追上 Watch 的状态。
public struct WorkoutStateSnapshot: Hashable, Codable, Sendable {
    public let configuration: WorkoutConfigurationRequest?
    public let phase: WorkoutSessionPhase
    public let startDate: Date?
    public let metrics: WorkoutMetricsSnapshot?
    public let saveStatus: WorkoutSaveStatus
    /// Watch 上设置的心率区间（v0.2 新增，可选；旧消息为 `nil`）。iPhone 用它显示当前区间。
    public let heartRateZones: HeartRateZoneSettings?
    /// 开启了震动提醒时的目标区间；未开启为 `nil`。
    public let targetZone: TrainingZone?

    public init(
        configuration: WorkoutConfigurationRequest?,
        phase: WorkoutSessionPhase,
        startDate: Date?,
        metrics: WorkoutMetricsSnapshot?,
        saveStatus: WorkoutSaveStatus = .pending,
        heartRateZones: HeartRateZoneSettings? = nil,
        targetZone: TrainingZone? = nil
    ) {
        self.configuration = configuration
        self.phase = phase
        self.startDate = startDate
        self.metrics = metrics
        self.saveStatus = saveStatus
        self.heartRateZones = heartRateZones
        self.targetZone = targetZone
    }

    private enum CodingKeys: String, CodingKey {
        case configuration, phase, startDate, metrics, saveStatus, heartRateZones, targetZone
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try container.decodeIfPresent(WorkoutConfigurationRequest.self, forKey: .configuration)
        phase = try container.decode(WorkoutSessionPhase.self, forKey: .phase)
        startDate = try container.decodeIfPresent(Date.self, forKey: .startDate)
        metrics = try container.decodeIfPresent(WorkoutMetricsSnapshot.self, forKey: .metrics)
        saveStatus = try container.decode(WorkoutSaveStatus.self, forKey: .saveStatus)
        // v0.2 新增的可选字段：取值不合法或无法识别时忽略，不能让整条状态同步失败。
        heartRateZones = try? container.decodeIfPresent(HeartRateZoneSettings.self, forKey: .heartRateZones)
        targetZone = try? container.decodeIfPresent(TrainingZone.self, forKey: .targetZone)
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
    /// Watch → iPhone：保存结果（在结束会话、关闭镜像之前发送）。
    case saveResult(WorkoutSaveStatus)
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
        // 先用 JSONSerialization 校验：部分 Foundation 版本的 JSONDecoder 遇到非法 UTF-8 或
        // 字符串中的控制字符会直接崩溃（内部 try!）而不是抛错。消息很小，二次解析开销可忽略。
        guard String(data: data, encoding: .utf8) != nil,
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw CodecError.malformedPayload
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
