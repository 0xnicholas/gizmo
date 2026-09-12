import Foundation

/// Kimi for Coding 归一化:`/coding/v1/usages` + `/coding/v1/me`。
///
/// - 主额度窗口(`usage`)= 周窗,kind=planWindow。resetTime 实测 ≈ +7 天;
///   官方 Kimi CLI 对无 window 字段的 `usage` 归一化为 {duration:1, unit:"week"}
///   (#48:原「日窗」标签源自调研期对 reset 时间戳的误读,数据从未缺失)。
/// - `limits[]` = 滚动频限窗(实测 300 分钟),kind=rateLimit,不参与 status。
/// - `parallel.limit` = 并发上限 → meta。
/// - `boosterWallet.balance.amount` 为固定点整数(÷1e6 得货币单位)→ Balance(.wallet)。
/// - Kimi 没有历史用量端点 → `rollingUsage` 恒为 nil(卡片不渲染该行)。
public struct KimiParser: ProviderParser {
    /// 固定点换算:Kimi booster 钱包以 1e6 为 1 个货币单位。
    static let fixedPointScale = Decimal(1_000_000)

    public init() {}

    public func parse(payload: ProviderPayload, fetchedAt: Date) throws -> Snapshot {
        let response = try payload.requirePrimary()
        guard response.statusCode == 200 else { throw FetchFailure.http(response.statusCode) }

        let root = try JSONReader.object(from: response.body, context: "kimi/usages")
        guard root["usage"] != nil || root["limits"] != nil || root["parallel"] != nil || root["boosterWallet"] != nil else {
            throw FetchFailure.parse("kimi/usages:缺少 usage/limits/parallel/boosterWallet")
        }

        var windows: [QuotaWindow] = []
        if let usage = JSONReader.object(root["usage"]),
           let window = QuotaWindow.make(
               kind: .planWindow,
               label: "周窗口",
               unit: "请求",
               limit: usage["limit"],
               used: usage["used"],
               remaining: usage["remaining"],
               resetAt: JSONReader.rfc3339Date(usage["resetTime"])
           ) {
            windows.append(window)
        }

        for item in JSONReader.array(root["limits"]) ?? [] {
            guard let limit = JSONReader.object(item), let detail = JSONReader.object(limit["detail"]) else {
                continue
            }
            let windowSpec = JSONReader.object(limit["window"])
            if let window = QuotaWindow.make(
                kind: .rateLimit,
                label: Self.rateLimitLabel(windowSpec),
                unit: "请求",
                limit: detail["limit"],
                used: detail["used"],
                remaining: detail["remaining"],
                resetAt: JSONReader.rfc3339Date(detail["resetTime"])
            ) {
                windows.append(window)
            }
        }

        var balances: [Balance] = []
        if let wallet = JSONReader.object(root["boosterWallet"]),
           let walletBalance = JSONReader.object(wallet["balance"]),
           // amountLeft 可能缺省、也可能显式为 null;两种都要退回 amount。
           let fixedPoint = JSONReader.decimal(walletBalance["amountLeft"])
               ?? JSONReader.decimal(walletBalance["amount"]) {
            balances.append(Balance(
                type: .wallet,
                amount: fixedPoint / Self.fixedPointScale,
                currency: Self.currency(of: wallet)
            ))
        }

        var plan: Plan?
        if let profileResponse = payload.response(.profile), profileResponse.statusCode == 200,
           let profile = try? JSONReader.object(from: profileResponse.body, context: "kimi/me"),
           // 只有 /me 真的给出档位名才算数;形状陌生的 200 响应不能顶掉
           // /usages 里已验证可用的 membership 元信息(否则会拿默认名当档位)。
           let level = JSONReader.string(profile["user_level_name"]) {
            plan = Plan(level: level, domain: JSONReader.string(profile["domain_name"]))
        }
        if plan == nil {
            let user = JSONReader.object(root["user"])
            let membership = user.flatMap { JSONReader.object($0["membership"]) }
            plan = Plan(
                level: membership.flatMap { JSONReader.string($0["level"]) } ?? "Kimi for Coding",
                domain: JSONReader.string(root["domain"])
            )
        }

        return Snapshot(
            meta: SnapshotMeta(
                provider: .kimi,
                plan: plan,
                fetchedAt: fetchedAt,
                concurrencyLimit: JSONReader.object(root["parallel"]).flatMap { JSONReader.int($0["limit"]) }
            ),
            windows: windows,
            balances: balances,
            rollingUsage: nil,
            raw: RawResponses.compose(RawResponses.entries(from: payload, parts: [.primary, .profile]))
        )
    }

    /// 频限窗口展示名:`window{duration,timeUnit}` →「频限 · 滚动窗(300 分钟)」。
    static func rateLimitLabel(_ windowSpec: [String: Any]?) -> String {
        guard let windowSpec,
              let duration = JSONReader.int(windowSpec["duration"]),
              let unit = timeUnitName(JSONReader.string(windowSpec["timeUnit"]))
        else {
            return "频限 · 滚动窗"
        }
        return "频限 · 滚动窗(\(duration) \(unit))"
    }

    static func timeUnitName(_ raw: String?) -> String? {
        switch raw {
        case "TIME_UNIT_MINUTE": return "分钟"
        case "TIME_UNIT_HOUR": return "小时"
        case "TIME_UNIT_DAY": return "天"
        case "TIME_UNIT_WEEK": return "周"
        default: return nil
        }
    }

    /// 钱包币种跟随月充值上限/已用金额(实测 CNY)。
    static func currency(of wallet: [String: Any]) -> String {
        for key in ["monthlyChargeLimit", "monthlyUsed"] {
            if let amount = JSONReader.object(wallet[key]),
               let currency = JSONReader.string(amount["currency"]) {
                return currency
            }
        }
        return "CNY"
    }
}
