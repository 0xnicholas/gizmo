import Foundation
import Testing
@testable import UsageMonitorCore

/// #18 验收标准第 3 条:解析器对 Authorization 头一无所知(不构造请求),输入输出均为纯数据。
///
/// 这些断言不看具体字段值,只管「纯函数 + 纯数据」这一层契约:
/// 同输入同输出、时间只来自注入值、raw 恰好等于响应体、输入结构上无处安放请求头。
@Suite("解析器纯数据契约")
struct ParserDataContractTests {
    private let cases: [(name: String, parser: any ProviderParser, body: String)] = [
        ("DeepSeek", DeepSeekParser(), ParserFixtures.deepseekBalance),
        ("Kimi", KimiParser(), ParserFixtures.kimiUsages),
        ("GLM", GLMParser(), ParserFixtures.glmQuota),
    ]

    @Test("纯函数:同输入两次解析结果全等,时间只来自注入值(不读系统时钟)")
    func parsersArePureFunctions() throws {
        // 哨兵时刻:离「现在」足够远,解析器若偷读 Date() 一眼就能看出。
        let injected = Date(timeIntervalSince1970: 42)

        for (name, parser, body) in cases {
            // 两次调用各自独立构造 payload(不共享引用),断言结果全等。
            let first = try parser.parse(payload: .ok(body), fetchedAt: injected)
            let second = try parser.parse(payload: .ok(body), fetchedAt: injected)

            #expect(first == second, "\(name):同输入两次解析结果不一致")
            #expect(first.meta.fetchedAt == injected, "\(name):fetchedAt 未原样透传注入值")
        }
    }

    @Test("raw 恰好是响应体本身:没有夹带任何请求侧数据")
    func rawIsExactlyTheResponseBody() throws {
        for (name, parser, body) in cases {
            let snapshot = try parser.parse(payload: .ok(body), fetchedAt: Fixture.epoch)
            #expect(snapshot.raw == body, "\(name):单分片 raw 不等于响应体原文")
        }
    }

    @Test("解析输入结构上无处携带请求头:响应只有状态码与响应体")
    func responsesCarryNoRequestHeaders() {
        // 红线:「raw 落快照前不得拼入 Authorization」在类型层面成立——
        // FetchResponse 只有 statusCode/body,解析器拿不到、也就构造不出请求。
        let response = FetchResponse(statusCode: 200, body: ParserFixtures.data("{}"))
        let fields = Mirror(reflecting: response).children.compactMap(\.label).sorted()
        #expect(fields == ["body", "statusCode"])
    }
}
