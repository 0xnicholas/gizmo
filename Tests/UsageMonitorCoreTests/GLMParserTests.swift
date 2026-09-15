import Foundation
import Testing
@testable import UsageMonitorCore

@Suite("GLM 额度窗口与近 7 天消耗解析")
struct GLMParserTests {
    let parser = GLMParser()
    let evaluator = StatusEvaluator()

    private func parse(_ payload: ProviderPayload) throws -> Snapshot {
        try parser.parse(payload: payload, fetchedAt: Fixture.epoch)
    }

    @Test("5 小时窗与 7 天窗:数值、标签、epoch 毫秒重置时间")
    func parsesWindows() throws {
        let snapshot = try parse(.ok(ParserFixtures.glmQuota))

        #expect(snapshot.meta.provider == .glm)
        #expect(snapshot.meta.plan == Plan(level: "pro"))
        #expect(snapshot.windows.count == 2)

        let fiveHour = snapshot.planWindows[0]
        #expect(fiveHour.label == "5 小时窗")
        #expect(fiveHour.unit == "积分")
        #expect(fiveHour.limit == 12_000)
        #expect(fiveHour.used == 641)
        #expect(fiveHour.remaining == 11_358)
        #expect(fiveHour.resetAt == Date(timeIntervalSince1970: 1_788_937_420.709))

        let weekly = snapshot.planWindows[1]
        #expect(weekly.label == "7 天窗")
        #expect(weekly.limit == 60_000)
        #expect(weekly.remaining == 15_929)
    }

    @Test("status 取窗口最低剩余占比:7 天窗 26.5% → 偏低")
    func statusFromWindows() throws {
        let snapshot = try parse(.ok(ParserFixtures.glmQuota))
        #expect(evaluator.status(for: snapshot) == .low)
    }

    @Test("近 7 天消耗 = 日桶求和")
    func rollingUsageSumsBuckets() throws {
        let snapshot = try parse(.ok(ParserFixtures.glmQuota)
            .merging(.ok(ParserFixtures.glmModelUsageDaily, part: .rollingUsage)))
        #expect(snapshot.rollingUsage == .value(amount: 7_500_000, unit: "tokens"))
    }

    @Test("近 7 天消耗分片失败 → .failed,其余额度照常成快照")
    func rollingUsageFailureDoesNotBreakCard() throws {
        let httpFailure = try parse(.ok(ParserFixtures.glmQuota)
            .merging(.response("{}", part: .rollingUsage, statusCode: 500)))
        #expect(httpFailure.rollingUsage == .failed)
        #expect(httpFailure.planWindows.count == 2)

        let transportFailure = try parse(.ok(ParserFixtures.glmQuota)
            .merging(.failure(.transport("timeout"), part: .rollingUsage)))
        #expect(transportFailure.rollingUsage == .failed)

        let businessFailure = try parse(.ok(ParserFixtures.glmQuota)
            .merging(.ok(#"{"code":500,"msg":"time range exceeds limit","success":false}"#, part: .rollingUsage)))
        #expect(businessFailure.rollingUsage == .failed)
    }

    @Test("未请求近 7 天消耗分片 → nil(不渲染该行)")
    func rollingUsageAbsent() throws {
        #expect(try parse(.ok(ParserFixtures.glmQuota)).rollingUsage == nil)
    }

    @Test("业务错误体(fast-fail)不产出快照")
    func businessError() {
        let body = #"{"code":500,"msg":"Parameter validation failed","success":false}"#
        #expect(throws: FetchFailure.self) {
            try parser.parse(payload: .ok(body), fetchedAt: Fixture.epoch)
        }
    }

    @Test("未知 type 不建模,但原文保留在 raw")
    func unknownTypePreserved() throws {
        let json = """
        {"code":200,"data":{"limits":[
          {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":12000,"currentValue":641,"remaining":11358,"nextResetTime":1788937420709},
          {"type":"FUTURE_LIMIT","unit":9,"number":9,"usage":100,"currentValue":1,"remaining":99,"nextResetTime":1788937420709}
        ],"level":"pro"},"success":true}
        """
        let snapshot = try parse(.ok(json))
        #expect(snapshot.windows.count == 1)
        #expect(snapshot.raw.contains("FUTURE_LIMIT"))
    }

    @Test("TOKENS_LIMIT / TIME_LIMIT 也建模为套餐窗口,标签按官方映射")
    func alternateTypes() throws {
        let json = """
        {"code":200,"data":{"limits":[
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":1000,"currentValue":100,"remaining":900},
          {"type":"TIME_LIMIT","unit":6,"number":1,"usage":100,"currentValue":91,"remaining":9}
        ],"level":"lite"},"success":true}
        """
        let snapshot = try parse(.ok(json))
        // 官方 intl 插件映射:TOKENS_LIMIT = Token usage(5 Hour)、TIME_LIMIT = MCP usage(1 Month)。
        // unit/number 编码只在 CREDIT_LIMIT 实测过,TIME_LIMIT 不套用(否则会把月度 MCP 额度标成 7 天窗)。
        #expect(snapshot.planWindows.map(\.label) == ["Token · 5 小时窗", "MCP · 月度窗"])
        #expect(evaluator.status(for: snapshot) == .critical)  // MCP 窗口 9%
    }

    @Test("正常响应逐字段归一化:meta / windows / balances / rollingUsage / raw")
    func normalizesWholeSnapshot() throws {
        let snapshot = try parse(.ok(ParserFixtures.glmQuota))

        #expect(snapshot == Snapshot(
            meta: SnapshotMeta(
                provider: .glm,
                plan: Plan(level: "pro"),
                fetchedAt: Fixture.epoch,
                concurrencyLimit: nil
            ),
            windows: [
                QuotaWindow(
                    kind: .planWindow, label: "5 小时窗", unit: "积分",
                    limit: 12_000, used: 641, remaining: 11_358,
                    resetAt: Date(timeIntervalSince1970: 1_788_937_420.709)
                ),
                QuotaWindow(
                    kind: .planWindow, label: "7 天窗", unit: "积分",
                    limit: 60_000, used: 44_070, remaining: 15_929,
                    resetAt: Date(timeIntervalSince1970: 1_789_177_578.997)
                ),
            ],
            balances: [],
            rollingUsage: nil,
            raw: ParserFixtures.glmQuota
        ))
    }

    @Test("缺字段:remaining / usage 可互相补全,缺 type 的行不建模")
    func derivesMissingFields() throws {
        let json = """
        {"code":200,"data":{"limits":[
          {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":12000,"currentValue":641},
          {"type":"CREDIT_LIMIT","unit":6,"number":1,"currentValue":44070,"remaining":15929},
          {"unit":9,"number":9,"usage":100,"currentValue":1,"remaining":99}
        ],"level":"pro"},"success":true}
        """
        let snapshot = try parse(.ok(json))

        #expect(snapshot.planWindows.count == 2)
        // 服务端三个数字只是近似自洽(实测 12000 - 641 = 11359,而 remaining 给 11358);
        // 字段在时原样透传,缺 remaining 时才按 usage - currentValue 推导。
        #expect(snapshot.planWindows[0].remaining == 11_359)
        #expect(snapshot.planWindows[1].limit == 59_999)      // currentValue + remaining
        #expect(snapshot.planWindows[1].used == 44_070)
        #expect(snapshot.raw.contains("\"unit\":9"))         // 未建模的行原文仍在
    }

    @Test("未知字段(含顶层)不丢:raw 逐字保留")
    func preservesUnknownFields() throws {
        let json = """
        {"code":200,"data":{"limits":[],"level":"pro","traceId":"t-1","future":{"a":1}},"success":true}
        """
        let snapshot = try parse(.ok(json))

        #expect(snapshot.raw == json)
        #expect(snapshot.raw.contains("traceId"))
        #expect(snapshot.windows.isEmpty)
    }

    @Test("业务错误体两种形态都不产出快照,即使带 data")
    func businessErrors() {
        // success=false 优先(即使体内有可解析的 data 段)
        let withData = #"{"code":500,"msg":"Parameter validation failed","success":false,"data":{"limits":[]}}"#
        #expect(throws: FetchFailure.self) {
            try parser.parse(payload: .ok(withData), fetchedAt: Fixture.epoch)
        }
        // 无 success 字段、code!=200 且无 data
        let bare = #"{"code":500,"message":"Internal error"}"#
        #expect(throws: FetchFailure.business(code: 500, message: "glm/quota:Internal error")) {
            try parser.parse(payload: .ok(bare), fetchedAt: Fixture.epoch)
        }
    }

    @Test("model-usage 超窗错误即使带 data 也判失败,不把错误体当 0 用量")
    func modelUsageBusinessErrorWithData() throws {
        let errorBody = #"{"code":500,"msg":"Parameter validation failed: incorrect time format or time range exceeds limit","success":false,"data":{"tokensUsage":[]}}"#
        let snapshot = try parse(.ok(ParserFixtures.glmQuota)
            .merging(.ok(errorBody, part: .rollingUsage)))

        #expect(snapshot.rollingUsage == .failed)
        #expect(snapshot.planWindows.count == 2)
    }

    @Test("model-usage 小时桶同样求和(只认窗口内总量,不认粒度标签)")
    func rollingUsageSumsHourlyBuckets() throws {
        let hourly = #"{"code":200,"data":{"x_time":["2026-09-08 10:00","2026-09-08 11:00"],"tokensUsage":[1,2],"granularity":"hourly"},"success":true}"#
        #expect(try parse(.ok(ParserFixtures.glmQuota).merging(.ok(hourly, part: .rollingUsage))).rollingUsage == .value(amount: 3, unit: "tokens"))
    }

    @Test("missing data / 非 200 → 失败")
    func failures() {
        #expect(throws: FetchFailure.self) {
            try parser.parse(payload: .ok(#"{"code":200,"success":true}"#), fetchedAt: Fixture.epoch)
        }
        #expect(throws: FetchFailure.http(429)) {
            try parser.parse(payload: .response("{}", statusCode: 429), fetchedAt: Fixture.epoch)
        }
    }

    @Test("raw 拼接多分片且不含请求头")
    func rawComposition() throws {
        let snapshot = try parse(.ok(ParserFixtures.glmQuota)
            .merging(.ok(ParserFixtures.glmModelUsageDaily, part: .rollingUsage)))
        #expect(snapshot.raw.hasPrefix("{\"primary\":"))
        #expect(snapshot.raw.contains("\"rollingUsage\":"))
        #expect(!snapshot.raw.lowercased().contains("authorization"))
    }
}

/// 套餐有效期(#53):订阅分片 → `planValidity` 派生字段。
///
/// 口径(glm-subscription-source.md 实测):有效期串形如
/// `yyyy-MM-dd HH:mm:ss-yyyy-MM-dd HH:mm:ss`,按北京时间(+08:00)解析;畸形串退回
/// 「无有效期信息」而不报错;多条记录取覆盖 now 的那条,都不覆盖则取末端最晚者。
/// 账单元数据(订单号/客户号/协议号/金额)既不落派生字段也不进 raw。
@Suite("GLM 套餐有效期(订阅分片)")
struct GLMSubscriptionTests {
    let parser = GLMParser()

    /// 注入时刻 = 2026-09-16 10:00(+08:00),落在实测的本期区间内(独立换算的 epoch 字面量)。
    private static let insidePeriod = Date(timeIntervalSince1970: 1_789_524_000)
    /// 实测区间端点:2026-09-15 10:00:00+08:00 / 2026-10-15 10:00:00+08:00。
    private static let periodStart = 1_789_437_600.0
    private static let periodEnd = 1_792_029_600.0

    private func parse(_ payload: ProviderPayload, now: Date = Self.insidePeriod) throws -> Snapshot {
        try parser.parse(payload: payload, fetchedAt: now)
    }

    /// 额度主分片 + 订阅分片(实测形状)。
    private func withSubscription(_ body: String = ParserFixtures.glmSubscription) -> ProviderPayload {
        .ok(ParserFixtures.glmQuota).merging(.ok(body, part: .subscription))
    }

    @Test("有效期起止按北京时间解析;status / autoRenew / productName 原样透传")
    func parsesValidityInBeijingTime() throws {
        let snapshot = try parse(withSubscription())

        let validity = try #require(snapshot.planValidity)
        #expect(validity.validFrom == Date(timeIntervalSince1970: Self.periodStart))
        #expect(validity.validUntil == Date(timeIntervalSince1970: Self.periodEnd))
        #expect(validity.status == "VALID")
        #expect(validity.autoRenew == false)
        #expect(validity.productName == "GLM Coding Pro")
        // 卡片其它字段完全不受影响
        #expect(snapshot.planWindows.count == 2)
        #expect(snapshot.meta.plan == Plan(level: "pro"))
    }

    @Test("响应含多条记录:取覆盖 now 的那条(不是末端最晚的那条)")
    func picksRecordCoveringNow() throws {
        let body = """
        {"code":200,"data":[
          {"productName":"GLM Coding Lite","status":"VALID","valid":"2026-08-15 10:00:00-2026-09-15 10:00:00","autoRenew":0},
          {"productName":"GLM Coding Pro","status":"VALID","valid":"2026-09-15 10:00:00-2026-10-15 10:00:00","autoRenew":0},
          {"productName":"GLM Coding Pro","status":"VALID","valid":"2026-10-15 10:00:00-2026-11-15 10:00:00","autoRenew":1}
        ],"success":true}
        """
        let snapshot = try parse(withSubscription(body))

        #expect(snapshot.planValidity?.validUntil == Date(timeIntervalSince1970: Self.periodEnd))
        #expect(snapshot.planValidity?.productName == "GLM Coding Pro")
        #expect(snapshot.planValidity?.autoRenew == false)
    }

    @Test("都不覆盖 now:取末端最晚者(已断供时露出最近一期,由到期判定接手)")
    func picksLatestEndWhenNoneCovers() throws {
        let body = """
        {"code":200,"data":[
          {"status":"VALID","valid":"2026-07-15 10:00:00-2026-08-15 10:00:00","autoRenew":0},
          {"status":"VALID","valid":"2026-08-15 10:00:00-2026-09-15 10:00:00","autoRenew":0}
        ],"success":true}
        """
        let snapshot = try parse(withSubscription(body))
        #expect(snapshot.planValidity?.validUntil == Date(timeIntervalSince1970: Self.periodStart))
        // 该条记录没有 productName / autoRenew 细节字段时保持 nil,不编造
        #expect(snapshot.planValidity?.productName == nil)
        #expect(snapshot.planValidity?.status == "VALID")
    }

    @Test("覆盖判定边界:now == 起刻算覆盖;now == 末端不算(下一期接手)")
    func coveringBoundaries() throws {
        let atStart = try parse(withSubscription())
        #expect(atStart.planValidity?.validUntil == Date(timeIntervalSince1970: Self.periodEnd))

        // 两期首尾相接:now 恰在衔接点 → 归下一期(到期当刻失效的口径一致)
        let body = """
        {"code":200,"data":[
          {"valid":"2026-09-15 10:00:00-2026-10-15 10:00:00","autoRenew":0},
          {"valid":"2026-10-15 10:00:00-2026-11-15 10:00:00","autoRenew":1}
        ],"success":true}
        """
        let atEnd = try parse(withSubscription(body), now: Date(timeIntervalSince1970: Self.periodEnd))
        #expect(atEnd.planValidity?.validUntil == Date(timeIntervalSince1970: 1_794_708_000))
        #expect(atEnd.planValidity?.autoRenew == true)
    }

    @Test("畸形有效期串退回「无有效期信息」:不报错、不猜、其它字段照常")
    func malformedPeriodDegradesSilently() throws {
        let malformed = [
            "2026-09-15 10:00:00",                          // 只有起刻
            "2026-09-15 10:00:00-2026-10-15T10:00:00",      // 带时区后缀/T 的形态(本期不做容错)
            "2026-09-15 10:00:00-2026-09-15 09:00:00",      // 末端早于起刻
            "2026-13-45 10:00:00-2026-10-15 10:00:00",      // 非法月日
            "not-a-period",
            "",
        ]
        for raw in malformed {
            let body = #"{"code":200,"data":[{"status":"VALID","valid":"\#(raw)","autoRenew":0}],"success":true}"#
            let snapshot = try parse(withSubscription(body))
            #expect(snapshot.planValidity == nil, "畸形串 \(raw) 应退回无有效期信息")
            #expect(snapshot.planWindows.count == 2, "畸形串 \(raw) 不应牵连额度字段")
        }
    }

    @Test("记录缺 valid / valid 非字符串 → 该条跳过;有可用记录时仍取之")
    func skipsRecordsWithoutValid() throws {
        let body = """
        {"code":200,"data":[
          {"status":"VALID"},
          {"valid":12345,"autoRenew":0},
          {"status":"VALID","valid":"2026-09-15 10:00:00-2026-10-15 10:00:00","autoRenew":1}
        ],"success":true}
        """
        let snapshot = try parse(withSubscription(body))
        #expect(snapshot.planValidity?.validUntil == Date(timeIntervalSince1970: Self.periodEnd))
    }

    @Test("首尾空白不构成畸形串(空白不属语义);内容仍须是完整定宽区间")
    func toleratesPaddingButNotPartialContent() throws {
        let padded = try parse(withSubscription(#"{"code":200,"data":[{"valid":"  2026-09-15 10:00:00-2026-10-15 10:00:00\n"}],"success":true}"#))
        #expect(try #require(padded.planValidity).validUntil == Date(timeIntervalSince1970: Self.periodEnd))
    }

    @Test("autoRenew 只认 0/1:未知取值退回 nil(不猜)")
    func autoRenewIsNotGuessed() throws {
        let body = #"{"code":200,"data":[{"valid":"2026-09-15 10:00:00-2026-10-15 10:00:00","autoRenew":2}],"success":true}"#
        #expect(try parse(withSubscription(body)).planValidity?.autoRenew == nil)

        let boolean = #"{"code":200,"data":[{"valid":"2026-09-15 10:00:00-2026-10-15 10:00:00","autoRenew":true}],"success":true}"#
        #expect(try parse(withSubscription(boolean)).planValidity?.autoRenew == true)
    }

    @Test("无订阅记录 / data 非数组 / data 缺失 → 无有效期信息")
    func absentRecordsDegradeSilently() throws {
        for body in [
            #"{"code":200,"data":[],"success":true}"#,
            #"{"code":200,"data":{},"success":true}"#,
            #"{"code":200,"success":true}"#,
            #"{}"#,
        ] {
            #expect(try parse(withSubscription(body)).planValidity == nil, "\(body) 应退回无有效期信息")
        }
    }

    @Test("订阅分片失败 / 非 200 / 业务错误 → 该行不出现,额度与近 7 天消耗照常")
    func shardFailureDegradesToTodaysShape() throws {
        let broken: [(String, ProviderPayload)] = [
            ("传输失败", .failure(.transport("timeout"), part: .subscription)),
            ("HTTP 500", .response("{}", part: .subscription, statusCode: 500)),
            ("业务错误", .ok(#"{"code":500,"msg":"Internal error","success":false}"#, part: .subscription)),
            ("响应体不是 JSON", .ok("not json", part: .subscription)),
        ]
        for (name, payload) in broken {
            let snapshot = try parse(.ok(ParserFixtures.glmQuota)
                .merging(.ok(ParserFixtures.glmModelUsageDaily, part: .rollingUsage))
                .merging(payload))
            #expect(snapshot.planValidity == nil, "\(name) 应退回无有效期信息")
            #expect(snapshot.planWindows.count == 2, "\(name) 不应牵连额度字段")
            #expect(snapshot.rollingUsage == .value(amount: 7_500_000, unit: "tokens"), "\(name) 不应牵连近 7 天消耗")
        }
    }

    @Test("未请求订阅分片 → 无有效期信息(该行不渲染)")
    func absentShardIsNil() throws {
        #expect(try parse(.ok(ParserFixtures.glmQuota)).planValidity == nil)
    }

    @Test("raw 白名单:订阅分片原文不进 raw,只留派生字段")
    func subscriptionStaysOutOfRaw() throws {
        let snapshot = try parse(withSubscription())

        #expect(snapshot.raw == ParserFixtures.glmQuota)
        for leaked in ["subscription", "orderNo", "customerId", "agreementNo", "payAmount", "EXAMPLE-ORDER-0001"] {
            #expect(!snapshot.raw.contains(leaked), "raw 不应含订阅分片痕迹:\(leaked)")
        }
        // 白名单内的派生字段照常落快照
        #expect(snapshot.planValidity?.productName == "GLM Coding Pro")
    }

    @Test("派生字段不含账单元数据:PlanValidity 只有有效期/status/autoRenew/productName")
    func validityCarriesNoBillingMetadata() throws {
        let snapshot = try parse(withSubscription())
        let validity = try #require(snapshot.planValidity)
        let fields = Mirror(reflecting: validity).children.compactMap(\.label).sorted()
        #expect(fields == ["autoRenew", "productName", "status", "validFrom", "validUntil"])
    }
}
