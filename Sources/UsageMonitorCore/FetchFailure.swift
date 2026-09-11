import Foundation

/// 拉取失败的分家:authError(凭据问题)与 networkError(可用性问题)必须分开。
public enum FetchFailure: Error, Equatable, Sendable {
    /// 网络/超时等适配器异常。
    case transport(String)
    /// 非 200/401/403 的 HTTP 状态。
    case http(Int)
    /// 401/403:重试一次后仍失败 → 该 provider 凭据「失效」。
    case auth(Int)
    /// HTTP 200 但业务错误体(如 GLM `code != 200`)。
    case business(code: Int, message: String)
    /// 响应形状不认识(字段缺失/类型不符)。
    case parse(String)

    /// 是否属于「凭据失效」而非「加载失败」。
    public var isAuthFailure: Bool {
        if case .auth = self { return true }
        return false
    }

    /// 脱敏错误描述:只含错误种类与状态码,不含响应体与凭据。
    public var descriptor: String {
        switch self {
        case .transport(let reason): return "网络错误(\(reason))"
        case .http(let status): return "HTTP \(status)"
        case .auth(let status): return "凭据失效(HTTP \(status))"
        case .business(let code, let message): return "业务错误 \(code):\(message)"
        case .parse(let reason): return "响应解析失败(\(reason))"
        }
    }
}
