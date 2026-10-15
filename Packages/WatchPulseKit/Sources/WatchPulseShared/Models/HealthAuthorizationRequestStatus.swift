/// 是否需要弹出 HealthKit 授权框，对应 `HKAuthorizationRequestStatus`。
///
/// `.unnecessary` 只代表“已经向用户展示过授权框”，**不代表**用户允许了读取。
public enum HealthAuthorizationRequestStatus: Hashable, Sendable {
    /// 尚未请求过，需要弹出授权框。
    case shouldRequest
    /// 已请求过，无需再次弹出。
    case unnecessary
    /// 无法确定。
    case unknown
}
