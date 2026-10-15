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
    public var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "此设备不支持健康数据，或健康数据访问受到限制。"
        case .protectedDataUnavailable:
            return "设备锁定时无法读取健康数据，请解锁 iPhone 后重试。"
        case .authorizationFailed(let reason):
            return "请求健康数据授权失败：\(reason)"
        case .queryFailed(let reason):
            return "读取健康数据失败：\(reason)"
        }
    }
}
