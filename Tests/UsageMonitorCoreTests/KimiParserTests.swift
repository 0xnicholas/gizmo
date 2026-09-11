import Foundation
import Testing
@testable import UsageMonitorCore

@Suite("Kimi 用量窗口解析")
struct KimiParserTests {
    let parser = KimiParser()
    let evaluator = StatusEvaluator()

    private func parse(_ payload: ProviderPayload) throws -> Snapshot {
        try parser.parse(payload: payload, fetchedAt: Fixture.epoch)
    }

    @Test("日窗 + 300 分钟频限窗 + 并发上限")
    func parsesWindowsAndLimit() throws {
        let snapshot = try parse(.ok(ParserFixtures.kimiUsages))

        #expect(snapshot.meta.concurrencyLimit == 20)
        #expect(snapshot.windows.count == 2)

        let day = snapshot.planWindows[0]
        #expect(day.label == "日窗口")
        #expect(day.unit == "会话")
        #expect(day.limit == 100)
        #expect(day.used == 98)
        #expect(day.remaining == 2)
        #expect(day.resetAt == ISO8601DateFormatter().date(from: "2026-09-10T08:24:54Z"))

        let rateLimit = snapshot.rateLimitWindows[0]
        #expect(rateLimit.label == "频限 · 滚动窗(300 分钟)")
        #expect(rateLimit.unit == "请求")
        #expect(rateLimit.remaining == 90)
        #expect(rateLimit.resetAt == ISO8601DateFormatter().date(from: "2026-09-09T06:24:54Z"))
    }

    @Test("频限窗不参与 status:日窗 2% → 临界")
    func statusIgnoresRateLimit() throws {
        let snapshot = try parse(.ok(ParserFixtures.kimiUsages))
        #expect(evaluator.status(for: snapshot) == .critical)

        // 反向:日窗充足、频限吃紧 → 仍为正常
        let relaxed = ParserFixtures.kimiUsages.replacingOccurrences(of: #""limit":"100","used":"98","remaining":"2""#, with: #""limit":"100","used":"20","remaining":"80""#)
        #expect(evaluator.status(for: try parse(.ok(relaxed))) == .normal)
    }

    @Test("booster 钱包固定点换算:amountLeft / 1e6")
    func parsesBoosterWallet() throws {
        let snapshot = try parse(.ok(ParserFixtures.kimiUsages))
        let wallet = snapshot.balances(ofType: .wallet)
        #expect(wallet == [Balance(type: .wallet, amount: Decimal(string: "3.5", locale: Locale(identifier: "en_US_POSIX"))!, currency: "CNY")])

        // amountLeft 缺省时退回 amount
        let fallback = ParserFixtures.kimiUsages.replacingOccurrences(of: #""amount":"2500000000","amountLeft":"3500000""#, with: #""amount":"2000000""#)
        #expect(try parse(.ok(fallback)).balances(ofType: .wallet).first?.amount == Decimal(2))
    }

    @Test("套餐元信息优先取 /me,缺 profile 时退回 /usages")
    func planMetadata() throws {
        let withProfile = try parse(.ok(ParserFixtures.kimiUsages)
            .merging(.ok(ParserFixtures.kimiProfile, part: .profile)))
        #expect(withProfile.meta.plan == Plan(level: "Allegretto", domain: "DOMAIN_NEXUS"))

        let withoutProfile = try parse(.ok(ParserFixtures.kimiUsages))
        #expect(withoutProfile.meta.plan?.level == "LEVEL_INTERMEDIATE")
        #expect(withoutProfile.meta.plan?.domain == "DOMAIN_NEXUS")
    }

    @Test("无直接来源:近 7 天用量为 nil(卡片不渲染该行)")
    func hasNoRollingUsage() throws {
        #expect(try parse(.ok(ParserFixtures.kimiUsages)).rollingUsage == nil)
        // profile 失败也不影响主数据
        let snapshot = try parse(.ok(ParserFixtures.kimiUsages)
            .merging(.failure(.transport("timeout"), part: .profile)))
        #expect(snapshot.meta.plan?.level == "LEVEL_INTERMEDIATE")
    }

    @Test("缺字段容错:remaining 可由 limit-used 补全;单条 limits 坏掉被跳过")
    func toleratesMissingFields() throws {
        let json = """
        {"usage":{"limit":"100","used":"30"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"}},{"detail":{"used":"10"}}]}
        """
        let snapshot = try parse(.ok(json))
        #expect(snapshot.planWindows.first?.remaining == 70)
        #expect(snapshot.planWindows.first?.resetAt == nil)
        #expect(snapshot.windows.count == 1)
    }

    @Test("完全未知的响应形状 → 解析失败")
    func unknownShape() {
        #expect(throws: FetchFailure.self) {
            try parser.parse(payload: .ok(#"{"hello":"world"}"#), fetchedAt: Fixture.epoch)
        }
    }

    @Test("raw 保留原始响应且不含凭据")
    func rawIsPreserved() throws {
        let snapshot = try parse(.ok(ParserFixtures.kimiUsages).merging(.ok(ParserFixtures.kimiProfile, part: .profile)))
        #expect(snapshot.raw.contains("boosterWallet"))
        #expect(snapshot.raw.contains("user_level_name"))
        #expect(!snapshot.raw.lowercased().contains("authorization"))
        #expect(!snapshot.raw.contains("Bearer"))
    }

    @Test("resetTime 为 RFC3339,带小数秒也可解析")
    func rfc3339WithFraction() throws {
        let json = #"{"usage":{"limit":"10","used":"1","remaining":"9","resetTime":"2026-09-10T08:24:54.123Z"}}"#
        let base = try #require(ISO8601DateFormatter().date(from: "2026-09-10T08:24:54Z"))
        let parsed = try #require(try parse(.ok(json)).planWindows.first?.resetAt)
        #expect(abs(parsed.timeIntervalSince(base) - 0.123) < 0.0005)
    }
}
