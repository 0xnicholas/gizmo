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

    @Test("正常响应逐字段归一化:/usages + /me 快照全等(含 raw 双分片拼接)")
    func normalizesWholeSnapshot() throws {
        let payload = ProviderPayload.ok(ParserFixtures.kimiUsages)
            .merging(.ok(ParserFixtures.kimiProfile, part: .profile))
        let snapshot = try parse(payload)

        #expect(snapshot == Snapshot(
            meta: SnapshotMeta(
                provider: .kimi,
                plan: Plan(level: "Allegretto", domain: "DOMAIN_NEXUS"),
                fetchedAt: Fixture.epoch,
                concurrencyLimit: 20
            ),
            windows: [
                QuotaWindow(
                    kind: .planWindow, label: "日窗口", unit: "会话",
                    limit: 100, used: 98, remaining: 2,
                    resetAt: ISO8601DateFormatter().date(from: "2026-09-10T08:24:54Z")
                ),
                QuotaWindow(
                    kind: .rateLimit, label: "频限 · 滚动窗(300 分钟)", unit: "请求",
                    limit: 100, used: 10, remaining: 90,
                    resetAt: ISO8601DateFormatter().date(from: "2026-09-09T06:24:54Z")
                ),
            ],
            balances: [Balance(type: .wallet, amount: Decimal(3_500_000) / Decimal(1_000_000), currency: "CNY")],
            rollingUsage: nil,
            raw: "{\"primary\":\(ParserFixtures.kimiUsages),\"profile\":\(ParserFixtures.kimiProfile)}"
        ))
    }

    @Test("缺 /me 分片时单分片同样全字段归一化:raw 即响应体原文")
    func normalizesWholeSnapshotWithoutProfile() throws {
        let snapshot = try parse(.ok(ParserFixtures.kimiUsages))

        #expect(snapshot.meta.plan == Plan(level: "LEVEL_INTERMEDIATE", domain: "DOMAIN_NEXUS"))
        #expect(snapshot.meta.fetchedAt == Fixture.epoch)
        #expect(snapshot.meta.accountAvailable == nil)
        #expect(snapshot.raw == ParserFixtures.kimiUsages)
    }

    @Test("未知字段(含嵌套)不丢:raw 逐字保留")
    func preservesUnknownFields() throws {
        let json = #"{"usage":{"limit":"10","used":"1","remaining":"9","window":{"duration":1,"timeUnit":"TIME_UNIT_DAY"}},"futureFeature":{"nested":["a",1]}}"#
        let snapshot = try parse(.ok(json))

        #expect(snapshot.raw == json)
        #expect(snapshot.raw.contains("futureFeature"))
        #expect(snapshot.raw.contains("TIME_UNIT_DAY"))
    }

    @Test("booster 固定点:1e6 为 1 单位,六位小数不丢精度")
    func walletFixedPointPrecision() throws {
        let one = try parse(.ok(#"{"boosterWallet":{"balance":{"amountLeft":"1"}}}"#))
        #expect(one.balances(ofType: .wallet).first?.amount == Decimal(string: "0.000001", locale: Locale(identifier: "en_US_POSIX")))

        let fraction = try parse(.ok(#"{"boosterWallet":{"balance":{"amountLeft":"1234567"}}}"#))
        #expect(fraction.balances(ofType: .wallet).first?.amount == Decimal(string: "1.234567", locale: Locale(identifier: "en_US_POSIX")))
    }

    @Test("amountLeft 为 null(而非缺省)时也要退回 amount")
    func walletNullAmountLeftFallsBack() throws {
        let json = #"{"boosterWallet":{"balance":{"amount":"2000000","amountLeft":null}}}"#
        #expect(try parse(.ok(json)).balances(ofType: .wallet).first?.amount == Decimal(2))
    }

    @Test("未知 timeUnit → 标签保守降级,窗口不丢")
    func unknownTimeUnitDegradesLabel() throws {
        let json = #"{"limits":[{"window":{"duration":45,"timeUnit":"TIME_UNIT_FORTNIGHT"},"detail":{"limit":"10","used":"1","remaining":"9"}}]}"#
        let window = try #require(try parse(.ok(json)).rateLimitWindows.first)

        #expect(window.label == "频限 · 滚动窗")
        #expect(window.remaining == 9)
    }

    @Test("401 错误体不产出快照:不因体内出现 usage 字样就当数据")
    func unauthorizedBodyIsNotParsed() {
        let body = #"{"error_description":"invalid token","usage":{"limit":"100","used":"1"}}"#
        #expect(throws: FetchFailure.http(401)) {
            try parser.parse(payload: .response(body, statusCode: 401), fetchedAt: Fixture.epoch)
        }
    }

    @Test("profile 分片 200 但形状陌生 → 退回 /usages 元信息")
    func malformedProfileFallsBack() throws {
        let payload = ProviderPayload.ok(ParserFixtures.kimiUsages)
            .merging(.ok(#"{"unexpected":true}"#, part: .profile))
        #expect(try parse(payload).meta.plan == Plan(level: "LEVEL_INTERMEDIATE", domain: "DOMAIN_NEXUS"))
    }
}
