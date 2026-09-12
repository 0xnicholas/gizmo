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
