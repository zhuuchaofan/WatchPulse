import Foundation

/// 健康数据访问错误。
///
/// 注意：HealthKit 不会告知 App “读取权限被拒绝”。读取被拒绝时，查询表现为返回空结果，
/// 因此这里没有“读取权限被拒绝”的错误；空结果应作为“无数据”处理。
public enum HealthDataError: Error, Hashable, Sendable {
    /// 当前设备不支持健康数据（例如部分 iPad），或被家长控制等限制。
    case healthDataUnavailable
    /// 设备锁定时健康数据库受保护，无法读取。
    case protectedDataUnavailable
    /// 授权请求本身失败（例如 Info.plist 缺少用途说明、entitlement 未配置）。
    case authorizationFailed(reason: String)
    /// 查询失败。
    case queryFailed(reason: String)
}

extension HealthDataError: LocalizedError {
    /// 给普通用户看的说明：发生了什么、下一步能做什么。**不包含**系统原始错误信息。
    public var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "这台设备无法使用“健康”数据，或访问受到限制。请在 iPhone 上使用 WatchPulse。"
        case .protectedDataUnavailable:
            return "iPhone 锁定时无法读取健康数据，请解锁后重试。"
        case .authorizationFailed:
            return "没能打开健康数据授权。请点“重试”；如果一直失败，请到「设置 › 隐私与安全性 › 健康 › WatchPulse」中检查。"
        case .queryFailed:
            return "暂时没能读取“健康”中的数据。请稍后重试；如果一直失败，可以重启 iPhone 后再试。"
        }
    }

    /// 开发调试用的诊断信息（含系统原始错误）。不要显示给用户。
    public var diagnosticDescription: String {
        switch self {
        case .healthDataUnavailable: return "healthDataUnavailable"
        case .protectedDataUnavailable: return "protectedDataUnavailable"
        case .authorizationFailed(let reason): return "authorizationFailed: \(reason)"
        case .queryFailed(let reason): return "queryFailed: \(reason)"
        }
    }
}
