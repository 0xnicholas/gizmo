import Foundation

/// GLM Coding Plan 归一化:`/api/monitor/usage/quota/limit` + `/api/monitor/usage/model-usage`
/// + `/api/biz/subscription/list`(套餐有效期)。
///
/// - `limits[]` → planWindow(5 小时窗 / 7 天窗)。`type` schema 在演进:
///   未知 type 不建模(原文仍留在 raw),避免污染 status 推导。
/// - `nextResetTime` 为 epoch 毫秒。
/// - 近 7 天消耗来自时序接口的日桶求和;该分片单独失败时 `rollingUsage = .failed`,
///   其余额度信息照常成快照(不影响卡片其它字段)。
/// - 套餐有效期来自订阅分片;该分片**静默退化**(失败/无记录/串畸形 → 无有效期信息),
///   且原文不进 raw(白名单例外)。
public struct GLMParser: ProviderParser {
    public init() {}

    /// raw 原文的**显式白名单**:只有用量类分片进快照原文(未知字段不丢的原则只覆盖它们)。
    /// 订阅分片刻意排除——它带订单号/客户号/协议号/金额类账单元数据,那些一概不落盘。
    static let rawParts: [FetchPart] = [.primary, .rollingUsage]

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
            guard let entry = JSONReader.object(item),
                  let rawType = JSONReader.string(entry["type"]),
                  let type = QuotaType(rawValue: rawType)
            else {
                continue
            }
            if let window = QuotaWindow.make(
                kind: .planWindow,
                label: type.label(unit: JSONReader.int(entry["unit"]), number: JSONReader.int(entry["number"])),
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
        let planValidity = Self.planValidity(from: payload.result(.subscription), now: fetchedAt)

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
            planValidity: planValidity,
            raw: RawResponses.compose(RawResponses.entries(from: payload, parts: Self.rawParts))
        )
    }

    /// 已知额度类型。schema 在演进,未知类型不建模(原文仍留在 raw)。
    enum QuotaType: String {
        case credit = "CREDIT_LIMIT"
        case tokens = "TOKENS_LIMIT"
        case time = "TIME_LIMIT"

        /// 窗口展示名。
        ///
        /// `TOKENS_LIMIT` / `TIME_LIMIT` 的窗口语义由 type 决定(官方 intl 插件映射:
        /// Token usage(5 Hour) / MCP usage(1 Month)),不套用 unit/number 编码——
        /// 该编码只在实测的 `CREDIT_LIMIT` 上验证过,套用会把月度 MCP 额度标成 7 天窗。
        func label(unit: Int?, number: Int?) -> String {
            switch self {
            case .time: return "MCP · 月度窗"
            case .tokens: return "Token · 5 小时窗"
            case .credit: return creditLabel(unit: unit, number: number)
            }
        }

        /// CREDIT_LIMIT(实测):unit=3&number=5 → 5 小时窗;unit=6&number=1 → 7 天窗(订阅锚点)。
        /// 其余组合保守降级为「窗口」,不猜单位语义。
        private func creditLabel(unit: Int?, number: Int?) -> String {
            switch (unit, number) {
            case (3, let number?): return "\(number) 小时窗"
            case (6, let number?): return number == 1 ? "7 天窗" : "\(number) 周窗"
            default: return "窗口"
            }
        }
    }

    // MARK: - 可选分片

    /// 可选分片的容错信封:传输失败 / 非 200 / 非 JSON / 业务错误体 → nil,
    /// 由调用方决定退化形态(近 7 天消耗 → `.failed`,有效期 → 无有效期信息),
    /// 也由调用方决定哪些分片进 raw(见 `rawParts`)。
    static func optionalShardObject(_ result: FetchPartResult, context: String) -> [String: Any]? {
        guard case .response(let response) = result, response.statusCode == 200,
              let root = try? JSONReader.object(from: response.body, context: context)
        else { return nil }
        do {
            try JSONReader.businessError(in: root, context: context)
        } catch {
            return nil
        }
        return root
    }

    /// 近 7 天消耗:请求窗口由适配器给定(自然滚动 7 天),此处只做日桶求和。
    static func rollingUsage(from result: FetchPartResult?) -> RollingUsage? {
        guard let result else { return nil }
        guard let root = optionalShardObject(result, context: "glm/model-usage"),
              let data = JSONReader.object(root["data"])
        else {
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

    // MARK: - 套餐有效期(订阅分片)

    /// 订阅分片 → 套餐有效期。**静默退化**:分片缺失/失败、响应无记录、有效期串畸形
    /// 都返回 nil(卡片不渲染该行,其它字段照常)。口径见 docs/research/glm-subscription-source.md。
    static func planValidity(from result: FetchPartResult?, now: Date) -> PlanValidity? {
        guard let result,
              let root = optionalShardObject(result, context: "glm/subscription"),
              let records = JSONReader.array(root["data"])
        else { return nil }

        let candidates: [PlanValidity] = records.compactMap { record in
            guard let record = JSONReader.object(record),
                  let period = JSONReader.string(record["valid"]),
                  let bounds = Self.periodBounds(of: period)
            else { return nil }
            return PlanValidity(
                validFrom: bounds.from,
                validUntil: bounds.until,
                status: JSONReader.string(record["status"]),
                autoRenew: Self.autoRenew(record["autoRenew"]),
                productName: JSONReader.string(record["productName"])
            )
        }

        // 实测「按协议一条记录、周期就地递增」(续订后同一字段自动推后),多条时:
        // 取覆盖 now 的那条;都不覆盖则取末端最晚者(断供后露出最近一期,交给到期判定)。
        return candidates.first { $0.covers(now) } ?? candidates.max { $0.validUntil < $1.validUntil }
    }

    /// 有效期串:`yyyy-MM-dd HH:mm:ss-yyyy-MM-dd HH:mm:ss`(北京时间 +08:00),定宽 39 字符。
    /// 首尾空白先裁掉(空白不属语义),其余畸形(定宽不符 / 无法解析 / 末端不晚于起刻)
    /// → nil,退回「无有效期信息」而不报错。
    /// 将来若返回带时区后缀的形态,容错扩在此处(spec 列为本期不做)。
    static func periodBounds(of raw: String) -> (from: Date, until: Date)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count == 39 else { return nil }
        let separator = text.index(text.startIndex, offsetBy: 19)
        guard text[separator] == "-" else { return nil }
        let startText = String(text[..<separator])
        let endText = String(text[text.index(after: separator)...])
        guard let from = beijingTime.date(from: startText),
              let until = beijingTime.date(from: endText),
              until > from
        else { return nil }
        return (from, until)
    }

    /// 有效期串的时区口径:实测串不带时区后缀,按北京时间(+08:00)解读;
    /// 与展示层共用 `PlanValidity.timeZone`(口径只此一处)。
    private static let beijingTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = PlanValidity.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// `autoRenew` 实测为 0/1 数字(布尔 JSON 亦归到此路径:true/false → 1/0);
    /// 其它取值(含未知枚举)一律 nil——展示「续订未知」比猜成 true 更诚实。
    static func autoRenew(_ value: Any?) -> Bool? {
        switch JSONReader.int(value) {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }
}
