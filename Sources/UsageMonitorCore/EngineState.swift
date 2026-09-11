import Foundation

/// 凭据在 UI 上的可见状态:值永不暴露。
public enum CredentialState: String, Codable, Sendable {
    /// 未配置(或已被清除)。
    case missing
    /// 已配置。
    case configured
    /// 凭据失效(401/403 重试一次后仍失败)。
    case invalid
}

/// 单个 provider 的运行时状态:快照 + 可用性 + 失败计数。
public struct ProviderRuntimeState: Equatable, Sendable {
    public var provider: Provider
    public var credential: CredentialState
    /// 最近一次成功快照;失败期间不清空。
    public var snapshot: Snapshot?
    /// 由当前持有快照推导的 status(UI 只消费不计算)。
    public var status: ProviderStatus
    public var lastSuccessAt: Date?
    public var lastAttemptAt: Date?
    /// networkError 连续失败轮数。
    public var consecutiveFailures: Int
    /// 连续失败达到阈值 →「加载失败」态(带上次成功时间与重试入口)。
    public var loadFailed: Bool
    /// 脱敏后的最近一次失败描述(不含响应体与凭据)。
    public var failureDescriptor: String?

    public init(provider: Provider) {
        self.provider = provider
        self.credential = .missing
        self.snapshot = nil
        self.status = .normal
        self.lastSuccessAt = nil
        self.lastAttemptAt = nil
        self.consecutiveFailures = 0
        self.loadFailed = false
        self.failureDescriptor = nil
    }

    /// 该家是否有可展示的数据。
    public var hasSnapshot: Bool { snapshot != nil }
}

/// 引擎对外发布的只读状态:UI 只依赖它。
public struct EngineState: Equatable, Sendable {
    public var providers: [Provider: ProviderRuntimeState]
    public var lastRefreshStartedAt: Date?
    public var lastRefreshFinishedAt: Date?
    public var isRefreshing: Bool
    /// 启动时凭据读取异常的家:状态未知,不等于「未配置」。
    public var credentialReadFailures: Set<Provider>
    public var overview: GlobalOverview

    public init(
        providers: [Provider: ProviderRuntimeState],
        lastRefreshStartedAt: Date? = nil,
        lastRefreshFinishedAt: Date? = nil,
        isRefreshing: Bool = false,
        credentialReadFailures: Set<Provider> = [],
        overview: GlobalOverview = GlobalOverview()
    ) {
        self.providers = providers
        self.lastRefreshStartedAt = lastRefreshStartedAt
        self.lastRefreshFinishedAt = lastRefreshFinishedAt
        self.isRefreshing = isRefreshing
        self.credentialReadFailures = credentialReadFailures
        self.overview = overview
    }

    public func provider(_ provider: Provider) -> ProviderRuntimeState {
        providers[provider] ?? ProviderRuntimeState(provider: provider)
    }

    /// 最近一次成功刷新的时刻(popover 脚注「上次更新」)。
    public var lastUpdatedAt: Date? {
        providers.values.compactMap(\.lastSuccessAt).max()
    }

    /// 是否存在任何已配置凭据(首次启动引导的一次性标志判定用)。
    public var hasAnyCredential: Bool {
        providers.values.contains { $0.credential != .missing }
    }

    /// 凭据失效或未配置的家数(顶部汇总横幅用);读取异常的家不计入,避免误报。
    public var pendingCredentialCount: Int {
        providers.values
            .filter { $0.credential != .configured && !credentialReadFailures.contains($0.provider) }
            .count
    }

    public var invalidCredentialCount: Int {
        providers.values.filter { $0.credential == .invalid }.count
    }

    public var missingCredentialCount: Int {
        providers.values.filter { $0.credential == .missing }.count
    }
}

/// 预警文案(通知与卡片共用口径)。
public struct UsageAlert: Equatable, Sendable {
    public enum Basis: Equatable, Sendable {
        /// plan-window 跨入临界:剩余 N <单位>(P%)。
        case window(label: String, remaining: Int, limit: Int, unit: String, percent: Int)
        /// 余额分界跨入临界(DeepSeek)。
        case balance(amount: Decimal, currency: String)
        /// provider 自报不可用(DeepSeek `is_available=false`)。
        case accountUnavailable
    }

    public var provider: Provider
    public var basis: Basis

    public init(provider: Provider, basis: Basis) {
        self.provider = provider
        self.basis = basis
    }

    /// 通知/横幅文案:「<provider> 剩余 N <单位>(P%),已达临界」。
    public var text: String {
        switch basis {
        case .window(_, let remaining, _, let unit, let percent):
            return "\(provider.displayName) 剩余 \(remaining) \(unit)(\(percent)%),已达临界"
        case .balance(let amount, let currency):
            return "\(provider.displayName) 余额 \(Money.format(amount, currency: currency)),已达临界"
        case .accountUnavailable:
            return "\(provider.displayName) 余额不可用,已达临界"
        }
    }
}

extension Provider {
    /// 凭据失效通知文案。
    public var credentialAlertText: String {
        "\(displayName) 凭据失效,请在设置中重新配置"
    }
}

/// 币种符号与金额展示(POSIX 小数点,不随系统区域漂移)。
public enum Money {
    public static func symbol(for currency: String) -> String {
        switch currency.uppercased() {
        case "CNY", "RMB": return "¥"
        case "USD": return "$"
        default: return currency.uppercased() + " "
        }
    }

    /// 两位小数的金额文本(DeepSeek 余额、Kimi 钱包)。
    public static func format(_ amount: Decimal, currency: String) -> String {
        symbol(for: currency) + format(amount)
    }

    public static func format(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = false
        return formatter.string(from: amount as NSDecimalNumber) ?? NSDecimalNumber(decimal: amount).stringValue
    }

    /// 计数型大数的分组展示(近 7 天 tokens)。
    public static func formatCount(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value))
    }
}
