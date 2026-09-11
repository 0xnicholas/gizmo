import Foundation

/// GLM Coding Plan 归一化:`/api/monitor/usage/quota/limit` + `/api/monitor/usage/model-usage`。
///
/// - `limits[]` → planWindow(5 小时窗 / 7 天窗)。`type` schema 在演进:
///   未知 type 不建模(原文仍留在 raw),避免污染 status 推导。
/// - `nextResetTime` 为 epoch 毫秒。
/// - 近 7 天用量来自时序接口的日桶求和;该分片单独失败时 `rollingUsage = .failed`,
///   其余额度信息照常成快照(不影响卡片其它字段)。
public struct GLMParser: ProviderParser {
    public init() {}

    public func parse(payload: ProviderPayload, fetchedAt: Date) throws -> Snapshot {
        let response = try payload.requirePrimary()
        guard response.statusCode == 200 else { throw FetchFailure.http(response.statusCode) }

        let root = try JSONReader.object(from: response.body, context: "glm/quota")
        try JSONReader.businessError(in: root, context: "glm/quota")
        guard let data = JSONReader.object(root["data"]) else {
            throw FetchFailure.parse("glm/quota:缺少 data")
        }

        var windows: [QuotaWindow] = []
        for item in JSONReader.array(data["limits"]) ?? [] {
            guard let entry = JSONReader.object(item), let type = JSONReader.string(entry["type"]),
                  Self.modeledTypes.contains(type)
            else {
                continue
            }
            if let window = QuotaWindow.make(
                kind: .planWindow,
                label: Self.label(type: type, unit: JSONReader.int(entry["unit"]), number: JSONReader.int(entry["number"])),
                unit: "积分",
                limit: entry["usage"],
                used: entry["currentValue"],
                remaining: entry["remaining"],
                resetAt: JSONReader.epochMilliseconds(entry["nextResetTime"])
            ) {
                windows.append(window)
            }
        }

        let rollingUsage = Self.rollingUsage(from: payload.result(.rollingUsage))

        return Snapshot(
            meta: SnapshotMeta(
                provider: .glm,
                plan: JSONReader.string(data["level"]).map { Plan(level: $0) },
                fetchedAt: fetchedAt,
                concurrencyLimit: nil
            ),
            windows: windows,
            balances: [],
            rollingUsage: rollingUsage,
            raw: RawResponses.compose(RawResponses.entries(from: payload, parts: [.primary, .rollingUsage]))
        )
    }

    /// 已知额度类型。`TIME_LIMIT` 为官方 intl 插件映射的 MCP 月度额度,同属套餐窗口。
    static let modeledTypes: Set<String> = ["CREDIT_LIMIT", "TOKENS_LIMIT", "TIME_LIMIT"]

    /// 窗口展示名。实测:unit=3&number=5 → 5 小时窗;unit=6&number=1 → 7 天窗(订阅锚点)。
    /// 其余组合保守降级为「窗口」,不猜单位语义。
    static func label(type: String, unit: Int?, number: Int?) -> String {
        var base = "窗口"
        switch (unit, number) {
        case (3, let number?): base = "\(number) 小时窗"
        case (6, let number?): base = number == 1 ? "7 天窗" : "\(number) 周窗"
        default: break
        }
        switch type {
        case "TIME_LIMIT": return "MCP · " + base
        case "TOKENS_LIMIT": return "Token · " + base
        default: return base
        }
    }

    /// 近 7 天用量:请求窗口由适配器给定(自然滚动 7 天),此处只做日桶求和。
    static func rollingUsage(from result: FetchPartResult?) -> RollingUsage? {
        guard let result else { return nil }
        guard case .response(let response) = result, response.statusCode == 200,
              let root = try? JSONReader.object(from: response.body, context: "glm/model-usage"),
              let data = JSONReader.object(root["data"])
        else {
            return .failed
        }
        do {
            try JSONReader.businessError(in: root, context: "glm/model-usage")
        } catch {
            return .failed
        }

        if let buckets = JSONReader.array(data["tokensUsage"]) {
            let total = buckets.reduce(0.0) { $0 + (JSONReader.double($1) ?? 0) }
            return .value(amount: total, unit: "tokens")
        }
        if let totalUsage = JSONReader.object(data["totalUsage"]),
           let total = JSONReader.double(totalUsage["totalTokensUsage"]) {
            return .value(amount: total, unit: "tokens")
        }
        return .failed
    }
}
