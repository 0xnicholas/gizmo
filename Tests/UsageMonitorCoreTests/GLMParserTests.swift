import Foundation
import Testing
@testable import UsageMonitorCore

@Suite("GLM 额度窗口与近 7 天用量解析")
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

    @Test("近 7 天用量 = 日桶求和")
    func rollingUsageSumsBuckets() throws {
        let snapshot = try parse(.ok(ParserFixtures.glmQuota)
            .merging(.ok(ParserFixtures.glmModelUsageDaily, part: .rollingUsage)))
        #expect(snapshot.rollingUsage == .value(amount: 7_500_000, unit: "tokens"))
    }

    @Test("近 7 天用量分片失败 → .failed,其余额度照常成快照")
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

    @Test("未请求近 7 天用量分片 → nil(不渲染该行)")
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

    @Test("TOKENS_LIMIT / TIME_LIMIT 也建模为套餐窗口")
    func alternateTypes() throws {
        let json = """
        {"code":200,"data":{"limits":[
          {"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":1000,"currentValue":100,"remaining":900},
          {"type":"TIME_LIMIT","unit":6,"number":1,"usage":100,"currentValue":91,"remaining":9}
        ],"level":"lite"},"success":true}
        """
        let snapshot = try parse(.ok(json))
        #expect(snapshot.planWindows.map(\.label) == ["Token · 5 小时窗", "MCP · 7 天窗"])
        #expect(evaluator.status(for: snapshot) == .critical)  // MCP 窗口 9%
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
