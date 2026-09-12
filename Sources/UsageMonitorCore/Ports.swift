import Foundation

/// 凭据存取端口:引擎每次刷新现读(不缓存、不监听);设置面经同一端口写入/清除。
/// UI 只感知「已配置 / 缺失 / 失效」状态,不感知值。
public protocol CredentialStore: Sendable {
    /// 读取凭据;不存在返回 nil。实现须去除返回值首尾空白,全空白视为不存在。
    func credential(for provider: Provider) throws -> String?
    /// 覆盖保存;写入失败须抛错。错误描述供设置面展示,不得包含凭据原文。
    func save(_ value: String, for provider: Provider) throws
    /// 清除;条目不存在不视为错误。
    func delete(for provider: Provider) throws
}

/// 一次 HTTP 响应:只含状态码与响应体(不含请求头,故不可能携带凭据)。
public struct FetchResponse: Equatable, Sendable {
    public var statusCode: Int
    public var body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// 一个 provider 的一次逻辑拉取所包含的端点分片。
public enum FetchPart: String, Codable, Sendable {
    /// 主数据端点:DeepSeek `/user/balance`、Kimi `/coding/v1/usages`、GLM `/api/monitor/usage/quota/limit`。
    case primary
    /// GLM 近 7 天用量时序(`/model-usage`)。
    case rollingUsage
    /// Kimi 账户资料(`/coding/v1/me`):套餐元信息。
    case profile
}

/// 分片结果:某分片单独失败不影响主分片成快照(如 GLM 近 7 天用量)。
public enum FetchPartResult: Equatable, Sendable {
    case response(FetchResponse)
    case failure(FetchFailure)
}

/// 一次拉取的全部原始响应;解析统一在 UsageMonitorCore 内完成。
public struct ProviderPayload: Equatable, Sendable {
    public var parts: [FetchPart: FetchPartResult]

    public init(parts: [FetchPart: FetchPartResult]) {
        self.parts = parts
    }

    public func result(_ part: FetchPart) -> FetchPartResult? {
        parts[part]
    }

    /// 分片是 HTTP 响应(无论状态码)时返回之。
    public func response(_ part: FetchPart) -> FetchResponse? {
        guard case .response(let response)? = parts[part] else { return nil }
        return response
    }

    /// 主分片:缺失按传输层失败处理。
    public func requirePrimary() throws -> FetchResponse {
        guard let response = response(.primary) else {
            throw FetchFailure.transport("响应缺失:\(FetchPart.primary.rawValue)")
        }
        return response
    }
}

/// 网络端口:每家一个实现,只负责发请求与收回响应。
public protocol ProviderFetching: Sendable {
    var provider: Provider { get }
    func fetch(credential: String) async throws -> ProviderPayload
}

/// 缓存端口:每 provider 最近一次成功快照。
public protocol SnapshotCache: Sendable {
    func loadSnapshots() throws -> [Provider: Snapshot]
    func saveSnapshot(_ snapshot: Snapshot) throws
}

/// 时钟端口:测试可拨。
public protocol Clock: Sendable {
    var now: Date { get }
}
