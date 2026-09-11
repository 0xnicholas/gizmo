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
}
