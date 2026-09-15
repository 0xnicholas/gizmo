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
    /// GLM 近 7 天消耗时序(`/model-usage`)。
    case rollingUsage
    /// GLM 订阅记录(`/api/biz/subscription/list`):有效期、自动续订与商品名。
    /// 该分片带账单元数据,原文**不进 raw**,只落派生字段(见 `GLMParser` 与 CONTEXT「raw 原文」)。
    case subscription
    /// Kimi 账户资料(`/coding/v1/me`):套餐元信息。
    case profile
}

/// 分片结果:某分片单独失败不影响主分片成快照(如 GLM 近 7 天消耗)。
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

/// 到期提醒的静默键(#57):值 = **已经提醒过的那条有效期端点**(不是时间戳)。
/// 同一个端点只提醒一次,改系统时间或重启都不会重复打扰;续订(端点推后)后
/// 端点一变、比较自然失配,静默键随之复位。
public struct PlanExpirySilenceKeys: Codable, Equatable, Sendable {
    /// 已就哪个有效期端点发过「即将到期」(nil = 还没发过)。
    public var approaching: Date?
    /// 已就哪个有效期端点发过「已到期」。
    public var expired: Date?

    public init(approaching: Date? = nil, expired: Date? = nil) {
        self.approaching = approaching
        self.expired = expired
    }
}

/// 静默键的存取端口:重启不重复打扰靠它的持久化(App 侧落 UserDefaults,
/// 测试/冒烟用内存实现)。读不到按「无记录」处理——方向偏「可能多提醒一次」,
/// 而不是「静默失效、再也不提醒」。
public protocol PlanExpirySilenceKeyStore: Sendable {
    func load() -> [Provider: PlanExpirySilenceKeys]
    func save(_ keys: [Provider: PlanExpirySilenceKeys])
}

/// 不跨进程存活的内存实现(测试与冒烟用;不碰真实用户的上次提醒记录)。
public final class InMemoryPlanExpirySilenceKeyStore: PlanExpirySilenceKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [Provider: PlanExpirySilenceKeys]

    public init(keys: [Provider: PlanExpirySilenceKeys] = [:]) {
        self.keys = keys
    }

    public func load() -> [Provider: PlanExpirySilenceKeys] {
        lock.lock()
        defer { lock.unlock() }
        return keys
    }

    public func save(_ keys: [Provider: PlanExpirySilenceKeys]) {
        lock.lock()
        defer { lock.unlock() }
        self.keys = keys
    }
}
