import Foundation
import Testing
@testable import UsageMonitorCore

@Suite("快照文件:合并、原子写后重读")
struct SnapshotFileCodecTests {
    let codec = SnapshotFileCodec()

    @Test("编码后重读:内容一致,顺序稳定")
    func roundTrip() throws {
        let glm = Fixture.snapshot(
            provider: .glm,
            windows: [Fixture.planWindow(limit: 12_000, remaining: 11_358, label: "5 小时窗")],
            rollingUsage: .value(amount: 7_500_000, unit: "tokens"),
            planValidity: Fixture.validity()
        )
        let deepseek = Fixture.snapshot(
            provider: .deepseek,
            balances: [Fixture.balance(.topUp, "59.27"), Fixture.balance(.granted, "3.20")],
            accountAvailable: true
        )

        let encoded = try codec.encode([.glm: glm, .deepseek: deepseek])
        let decoded = try codec.decode(encoded)
        #expect(decoded == [.glm: glm, .deepseek: deepseek])

        // 顺序按 Provider.allCases,重编码幂等(便于人工 diff)
        let again = try codec.encode(decoded)
        #expect(again == encoded)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(text.contains("plan-window"))
        #expect(!text.lowercased().contains("authorization"))
    }

    @Test("只覆盖该 provider:其他家原样保留")
    func mergingKeepsOtherProviders() {
        let oldGLM = Fixture.snapshot(provider: .glm, windows: [Fixture.planWindow(limit: 100, remaining: 90)])
        let newGLM = Fixture.snapshot(provider: .glm, windows: [Fixture.planWindow(limit: 100, remaining: 10)])
        let kimi = Fixture.snapshot(provider: .kimi)

        let merged = codec.merging(newGLM, into: [.glm: oldGLM, .kimi: kimi])
        #expect(merged[.glm] == newGLM)
        #expect(merged[.kimi] == kimi)
        #expect(merged.count == 2)
    }

    @Test("空文件与坏数据:不崩溃(空按无缓存,坏数据抛错)")
    func decodingEdgeCases() throws {
        #expect(try codec.decode(Data()).isEmpty)
        #expect(throws: (any Error).self) {
            try codec.decode(Data("{ not json".utf8))
        }
    }

    @Test("旧缓存文件(无 planValidity 字段)读出为「无有效期信息」,版本不升")
    func decodesLegacyFileWithoutPlanValidity() throws {
        // #53 前的落盘形状:结构里根本没有 planValidity 这个键。
        let legacy = Data(#"{"version":1,"snapshots":[{"meta":{"provider":"glm","plan":{"level":"pro"},"fetchedAt":"2023-11-14T22:13:20Z"},"windows":[],"balances":[],"raw":"{}"}]}"#.utf8)

        let decoded = try codec.decode(legacy)
        #expect(decoded[.glm]?.planValidity == nil)
        #expect(decoded[.glm]?.meta.fetchedAt == Fixture.epoch)

        // 新增可空字段不升版本;缺省字段不落成 null(旧文件形状保持不变)。
        let reencoded = try codec.encode(decoded)
        let file = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(file["version"] as? Int == 1)
        #expect(SnapshotFileCodec.currentVersion == 1)
        let text = try #require(String(data: reencoded, encoding: .utf8))
        #expect(!text.contains("planValidity"))
    }

    @Test("订阅账单元数据不进缓存文件(#53 白名单例外),有效期派生字段照常落盘")
    func encodedFileExcludesSubscriptionBillingMetadata() throws {
        let payload = ProviderPayload.ok(ParserFixtures.glmQuota)
            .merging(.ok(ParserFixtures.glmSubscription, part: .subscription))
        let snapshot = try GLMParser().parse(payload: payload, fetchedAt: Fixture.epoch)
        let encoded = try codec.encode([.glm: snapshot])
        let text = try #require(String(data: encoded, encoding: .utf8))

        for leaked in [
            "orderNo", "customerId", "agreementNo", "payAmount",
            "EXAMPLE-ORDER-0001", "EXAMPLE-CUSTOMER-0001", "EXAMPLE-AGREEMENT-0001",
        ] {
            #expect(!text.contains(leaked), "缓存文件不应含账单元数据:\(leaked)")
        }
        #expect(text.contains("planValidity"))
        #expect(try codec.decode(encoded)[.glm]?.planValidity == snapshot.planValidity)
    }
}
