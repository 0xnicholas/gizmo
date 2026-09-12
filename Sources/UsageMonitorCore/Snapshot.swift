import Foundation

/// 一次刷新后,某 provider 全部用量信息的归一化视图。
public struct Snapshot: Codable, Equatable, Sendable {
    public var meta: SnapshotMeta
    public var windows: [QuotaWindow]
    public var balances: [Balance]
    /// 近 7 天消耗:只在 provider 有直接用量数据源时非 nil(见 `RollingUsage`)。
    public var rollingUsage: RollingUsage?
    /// 原始响应原文(不含任何请求头),未知字段不丢。
    public var raw: String

    public init(
        meta: SnapshotMeta,
        windows: [QuotaWindow],
        balances: [Balance],
        rollingUsage: RollingUsage? = nil,
        raw: String
    ) {
        self.meta = meta
        self.windows = windows
        self.balances = balances
        self.rollingUsage = rollingUsage
        self.raw = raw
    }
}

public struct SnapshotMeta: Codable, Equatable, Sendable {
    public var provider: Provider
    public var plan: Plan?
    public var fetchedAt: Date
    /// 纯固定上限(如 Kimi 并发数);以「窗口 + 重置时间」表达的频限一律建模为 QuotaWindow。
    public var concurrencyLimit: Int?
    /// provider 自报的账户可用性(DeepSeek `is_available`);nil = 该 provider 无此字段。
    public var accountAvailable: Bool?

    public init(
        provider: Provider,
        plan: Plan?,
        fetchedAt: Date,
        concurrencyLimit: Int?,
        accountAvailable: Bool? = nil
    ) {
        self.provider = provider
        self.plan = plan
        self.fetchedAt = fetchedAt
        self.concurrencyLimit = concurrencyLimit
        self.accountAvailable = accountAvailable
    }
}

public struct Plan: Codable, Equatable, Sendable {
    public var level: String
    public var domain: String?

    public init(level: String, domain: String? = nil) {
        self.level = level
        self.domain = domain
    }
}

// MARK: - 派生视图

extension Snapshot {
    public var planWindows: [QuotaWindow] {
        windows.filter { $0.kind == .planWindow }
    }

    public var rateLimitWindows: [QuotaWindow] {
        windows.filter { $0.kind == .rateLimit }
    }

    /// 该快照持有的币种,按字母序(结果稳定,便于 UI 与测试)。
    public var currencies: [String] {
        Array(Set(balances.map(\.currency))).sorted()
    }

    /// 判定与展示 DeepSeek 余额分界所用的主币种:优先 CNY,否则取总额最大者(并列取字母序)。
    public var primaryCurrency: String? {
        if balances.contains(where: { $0.currency == "CNY" }) { return "CNY" }
        return currencies.max { lhs, rhs in
            totalBalance(currency: lhs) < totalBalance(currency: rhs)
        }
    }

    public func totalBalance(currency: String) -> Decimal {
        balances.filter { $0.currency == currency }.reduce(Decimal.zero) { $0 + $1.amount }
    }

    public var primaryCurrencyTotal: Decimal? {
        guard let currency = primaryCurrency else { return nil }
        return totalBalance(currency: currency)
    }

    public func balances(ofType type: Balance.Kind) -> [Balance] {
        balances.filter { $0.type == type }
    }
}

extension QuotaWindow {
    /// 剩余占比;limit 非正时无法判定 → nil。
    public var remainingFraction: Double? {
        guard limit > 0 else { return nil }
        return Double(remaining) / Double(limit)
    }
}
