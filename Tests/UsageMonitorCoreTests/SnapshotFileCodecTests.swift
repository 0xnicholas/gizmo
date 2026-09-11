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
            rollingUsage: .value(amount: 7_500_000, unit: "tokens")
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
}
