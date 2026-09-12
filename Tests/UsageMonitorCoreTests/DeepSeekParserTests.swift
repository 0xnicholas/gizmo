import Foundation
import Testing
@testable import UsageMonitorCore

@Suite("DeepSeek 余额解析")
struct DeepSeekParserTests {
    let parser = DeepSeekParser()
    let evaluator = StatusEvaluator()

    @Test("充值/赠送构成与 is_available 归一化")
    func parsesBalanceComposition() throws {
        let snapshot = try parser.parse(payload: .ok(ParserFixtures.deepseekBalance), fetchedAt: Fixture.epoch)

        #expect(snapshot.meta.provider == .deepseek)
        #expect(snapshot.meta.accountAvailable == true)
        #expect(snapshot.windows.isEmpty)
        #expect(snapshot.rollingUsage == nil)
        #expect(snapshot.balances(ofType: .topUp) == [Fixture.balance(.topUp, "59.27")])
        #expect(snapshot.balances(ofType: .granted) == [Fixture.balance(.granted, "3.20")])
        #expect(snapshot.totalBalance(currency: "CNY") == Decimal(string: "62.47", locale: Locale(identifier: "en_US_POSIX")))
        #expect(evaluator.status(for: snapshot) == .normal)
    }

    @Test("多币种按 currency 拆分,主币种为 CNY")
    func splitsCurrencies() throws {
        let snapshot = try parser.parse(payload: .ok(ParserFixtures.deepseekMultiCurrency), fetchedAt: Fixture.epoch)

        #expect(snapshot.currencies == ["CNY", "USD"])
        #expect(snapshot.primaryCurrency == "CNY")
        #expect(snapshot.totalBalance(currency: "USD") == Decimal(string: "1000.00", locale: Locale(identifier: "en_US_POSIX")))
        #expect(evaluator.status(for: snapshot) == .critical)  // 主币种 ¥8 < ¥10
    }

    @Test("is_available=false → 临界")
    func unavailable() throws {
        let snapshot = try parser.parse(payload: .ok(ParserFixtures.deepseekUnavailable), fetchedAt: Fixture.epoch)
        #expect(snapshot.meta.accountAvailable == false)
        #expect(evaluator.status(for: snapshot) == .critical)
    }

    @Test("未知字段不丢:原文进入 raw")
    func preservesUnknownFields() throws {
        let json = #"{"is_available":true,"new_field":{"a":1},"balance_infos":[]}"#
        let snapshot = try parser.parse(payload: .ok(json), fetchedAt: Fixture.epoch)
        #expect(snapshot.raw == json)
        #expect(snapshot.raw.contains("new_field"))
        #expect(!snapshot.raw.contains("Authorization"))
    }

    @Test("缺字段容错:坏 balance_infos 条目被跳过而非崩溃")
    func toleratesMalformedEntries() throws {
        let json = #"{"is_available":true,"balance_infos":[{"currency":"CNY"},{"topped_up_balance":"1.00"},{"currency":"CNY","topped_up_balance":"5.00"}]}"#
        let snapshot = try parser.parse(payload: .ok(json), fetchedAt: Fixture.epoch)
        #expect(snapshot.balances == [Fixture.balance(.topUp, "5.00")])
    }

    @Test("响应形状不认识 → 解析失败")
    func unknownShape() {
        #expect(throws: FetchFailure.self) {
            try parser.parse(payload: .ok(#"{"error":"unexpected"}"#), fetchedAt: Fixture.epoch)
        }
    }

    @Test("非 200 → http 失败")
    func httpFailure() {
        #expect(throws: FetchFailure.http(500)) {
            try parser.parse(payload: .response("{}", statusCode: 500), fetchedAt: Fixture.epoch)
        }
    }

    @Test("主分片缺失 → 传输层失败")
    func missingPrimary() {
        #expect(throws: FetchFailure.self) {
            try parser.parse(payload: ProviderPayload(parts: [:]), fetchedAt: Fixture.epoch)
        }
    }

    @Test("正常响应逐字段归一化:meta / windows / balances / rollingUsage / raw")
    func normalizesWholeSnapshot() throws {
        let snapshot = try parser.parse(payload: .ok(ParserFixtures.deepseekBalance), fetchedAt: Fixture.epoch)

        #expect(snapshot == Snapshot(
            meta: SnapshotMeta(
                provider: .deepseek,
                plan: nil,
                fetchedAt: Fixture.epoch,
                concurrencyLimit: nil,
                accountAvailable: true
            ),
            windows: [],
            balances: [
                Fixture.balance(.topUp, "59.27"),
                Fixture.balance(.granted, "3.20"),
            ],
            rollingUsage: nil,
            raw: ParserFixtures.deepseekBalance
        ))
    }

    @Test("多币种:无 CNY 时主币种退回总额最大者")
    func fallsBackToLargestCurrency() throws {
        let json = #"{"is_available":true,"balance_infos":[{"currency":"USD","topped_up_balance":"12.50"},{"currency":"EUR","topped_up_balance":"3.00"}]}"#
        let snapshot = try parser.parse(payload: .ok(json), fetchedAt: Fixture.epoch)

        #expect(snapshot.currencies == ["EUR", "USD"])
        #expect(snapshot.primaryCurrency == "USD")
        #expect(snapshot.primaryCurrencyTotal == Decimal(string: "12.50", locale: Locale(identifier: "en_US_POSIX")))
        #expect(snapshot.totalBalance(currency: "CNY") == 0)
    }

    @Test("缺字段:只给总余额时不臆造分项,原文仍留在 raw")
    func doesNotInventComponents() throws {
        let json = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"9.99"}]}"#
        let snapshot = try parser.parse(payload: .ok(json), fetchedAt: Fixture.epoch)

        #expect(snapshot.balances.isEmpty)
        #expect(snapshot.totalBalance(currency: "CNY") == 0)
        #expect(snapshot.raw.contains("9.99"))
    }

    @Test("缺字段:is_available 缺失 → nil(不臆造可用性)")
    func missingAvailability() throws {
        let json = #"{"balance_infos":[{"currency":"CNY","topped_up_balance":"20.00"}]}"#
        let snapshot = try parser.parse(payload: .ok(json), fetchedAt: Fixture.epoch)

        #expect(snapshot.meta.accountAvailable == nil)
        #expect(snapshot.totalBalance(currency: "CNY") == Decimal(string: "20.00", locale: Locale(identifier: "en_US_POSIX")))
    }

    @Test("402 余额耗尽的错误体不产出快照(状态码优先于响应体形状)")
    func insufficientBalanceBodyIsNotParsed() {
        let body = #"{"error":{"message":"Insufficient Balance","type":"insufficient_balance"}}"#
        #expect(throws: FetchFailure.http(402)) {
            try parser.parse(payload: .response(body, statusCode: 402), fetchedAt: Fixture.epoch)
        }
    }
}
