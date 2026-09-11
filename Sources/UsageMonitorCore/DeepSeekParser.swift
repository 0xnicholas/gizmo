import Foundation

/// DeepSeek `GET https://api.deepseek.com/user/balance` 归一化。
///
/// 余额为 string 金额;多币种按 `currency` 拆分为独立 `Balance`(不做跨源换算)。
/// DeepSeek 没有周期额度窗口 → `windows` 恒为空,status 走余额分界。
public struct DeepSeekParser: ProviderParser {
    public init() {}

    public func parse(payload: ProviderPayload, fetchedAt: Date) throws -> Snapshot {
        let response = try payload.requirePrimary()
        guard response.statusCode == 200 else { throw FetchFailure.http(response.statusCode) }

        let root = try JSONReader.object(from: response.body, context: "deepseek/balance")
        guard root["is_available"] != nil || root["balance_infos"] != nil else {
            throw FetchFailure.parse("deepseek/balance:缺少 is_available/balance_infos")
        }

        var balances: [Balance] = []
        for item in JSONReader.array(root["balance_infos"]) ?? [] {
            guard let info = JSONReader.object(item), let currency = JSONReader.string(info["currency"]) else {
                continue
            }
            if let toppedUp = JSONReader.decimal(info["topped_up_balance"]) {
                balances.append(Balance(type: .topUp, amount: toppedUp, currency: currency))
            }
            if let granted = JSONReader.decimal(info["granted_balance"]) {
                balances.append(Balance(type: .granted, amount: granted, currency: currency))
            }
        }

        return Snapshot(
            meta: SnapshotMeta(
                provider: .deepseek,
                plan: nil,
                fetchedAt: fetchedAt,
                concurrencyLimit: nil,
                accountAvailable: JSONReader.bool(root["is_available"])
            ),
            windows: [],
            balances: balances,
            rollingUsage: nil,
            raw: RawResponses.compose([(.primary, response.body)])
        )
    }
}
