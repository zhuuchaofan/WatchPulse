import Foundation

/// iPhone 发给 Watch 的远程控制命令。
public enum WorkoutRemoteCommand: String, Codable, Sendable {
    case pause
    case resume
    case end
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
    /// iPhone → Watch：控制命令。
    case command(WorkoutRemoteCommand)
}

/// 镜像消息的编解码器。消息外层带版本号，便于两端 App 版本不一致时安全拒绝。
public enum WorkoutMirroringCodec {
    public static let currentVersion = 1

    public enum CodecError: Error, Equatable, Sendable {
        case unsupportedVersion(Int)
        case malformedPayload
    }

    private struct Envelope: Codable {
        let version: Int
        let message: WorkoutMirroringMessage
    }

    private struct VersionProbe: Decodable {
        let version: Int
    }

    public static func encode(_ message: WorkoutMirroringMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(Envelope(version: currentVersion, message: message))
    }

    public static func decode(_ data: Data) throws -> WorkoutMirroringMessage {
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
            return try decoder.decode(Envelope.self, from: data).message
        } catch {
            throw CodecError.malformedPayload
        }
    }
}
