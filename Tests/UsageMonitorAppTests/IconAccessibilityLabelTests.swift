import Foundation
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// 菜单栏图标 a11y 一行说明(IC-2,P2-7,#45):VoiceOver 读的不只是图标本体的
/// 数字——「全局最紧剩余 65%,GLM 7 天窗;最差状态:DeepSeek 临界」同时报
/// 数字口径(最紧窗)与全局最差状态,补足口径乙后图标本体信息收窄
/// (颜色随数字、全局最差退居总览条/通知)的盲区。
@Suite("图标 a11y 一行说明(IC-2)")
struct IconAccessibilityLabelTests {
    private func label(_ state: EngineState) -> String {
        IconAccessibilityPresentation(state: state).text
    }

    /// spec 定稿形态:DeepSeek 余额临界 + GLM 7 天窗 65%——数字与最差分属两家,
    /// label 一行同时报两个口径。
    @Test("主形态:同时报最紧窗与全局最差(spec 定稿例)")
    func reportsTightestAndWorstTogether() {
        #expect(label(PreviewData.deepseekCriticalWithWindowsState())
            == "全局最紧剩余 65%,GLM 7 天窗;最差状态:DeepSeek 临界")
    }

    @Test("全正常:最差半句收成「全部正常」,不点名凑数")
    func allNormalCollapsesWorstClause() {
        #expect(label(PreviewData.normalState())
            == "全局最紧剩余 65%,GLM 7 天窗;最差状态:全部正常")
    }

    @Test("多家并列最差:按展示序「、」连接")
    func multipleWorstProvidersJoined() {
        let state = EngineState(
            providers: [
                .glm: PreviewData.runtime(.glm, snapshot: PreviewData.glm(weeklyRemaining: 3_000)),
                .kimi: PreviewData.runtime(.kimi, snapshot: PreviewData.kimi(weekRemaining: 66)),
                .deepseek: PreviewData.runtime(.deepseek, snapshot: PreviewData.deepseek(total: "8.20")),
            ],
            overview: GlobalOverview.compute(
                snapshots: [
                    .glm: PreviewData.glm(weeklyRemaining: 3_000),
                    .kimi: PreviewData.kimi(weekRemaining: 66),
                    .deepseek: PreviewData.deepseek(total: "8.20"),
                ],
                evaluator: StatusEvaluator(),
                now: Date()
            )
        )
        #expect(label(state) == "全局最紧剩余 5%,GLM 7 天窗;最差状态:GLM、DeepSeek 临界")
    }

    /// DeepSeek-only(彩色「—」形态):无任何 plan-window,最差半句仍可读。
    @Test("无窗口:承认暂无窗口数据,最差半句保留")
    func noWindowsKeepsWorstClause() {
        #expect(label(PreviewData.deepseekOnlyCriticalState())
            == "暂无窗口数据;最差状态:DeepSeek 临界")
    }

    @Test("全新安装:灰「—」对应的兜底文案")
    func freshInstallFallback() {
        #expect(label(PreviewData.freshState()) == "用量监视器,尚无数据")
    }

    /// 凭据失效的家持旧临界快照时与总览条 alertLine 同口径:不点名(凭据问题归横幅),
    /// 最差半句退到状态词本身。
    @Test("最差家凭据失效:退化为状态词,不点名")
    func worstProviderCredentialInvalidFallsBackToStatusWord() {
        let state = EngineState(
            providers: [
                .kimi: PreviewData.runtime(
                    .kimi,
                    snapshot: PreviewData.kimi(weekRemaining: 5),
                    credential: .invalid
                ),
            ],
            overview: GlobalOverview.compute(
                snapshots: [.kimi: PreviewData.kimi(weekRemaining: 5)],
                evaluator: StatusEvaluator(),
                now: Date()
            )
        )
        #expect(label(state) == "全局最紧剩余 5%,Kimi 周窗口;最差状态:临界")
    }
}

/// 到期退出全局口径后的 a11y 承认(#56):到期家退出最紧/最差点名,但一行说明
/// 补「已到期:」半句——退出口径的家在结论区无痕,用户就只能逐个 tab 找;
/// 三家全到期时「—」必须讲清来历,不产生「是不是没联网」的歧义。
@Suite("图标 a11y 的到期口径(#56)")
struct IconAccessibilityExpiryTests {
    private func label(_ state: EngineState) -> String {
        IconAccessibilityPresentation(state: state).text
    }

    @Test("部分到期:最紧/最差由未到期家决定,尾部承认「已到期:」")
    func partialExpiryAppendsAcknowledgement() {
        #expect(label(PreviewData.glmExpiredState())
            == "全局最紧剩余 66%,Kimi 周窗口;最差状态:全部正常;已到期:GLM")
    }

    @Test("三家全到期:一行讲清,不给「—」留歧义")
    func allExpiredExplainsTheDash() {
        #expect(label(PreviewData.allPlansExpiredState())
            == "用量监视器,三家套餐均已到期")
    }

    @Test("到期家凭据失效:不点名(凭据问题优先于到期,归横幅)")
    func expiredProviderWithInvalidCredentialIsNotNamed() {
        let expiredValidity = PreviewData.validity(untilDays: -2, fromDays: -32)
        let providers: [Provider: ProviderRuntimeState] = [
            .glm: PreviewData.runtime(
                .glm,
                snapshot: PreviewData.glm(weeklyRemaining: 3_000, validity: expiredValidity),
                credential: .invalid
            ),
            .kimi: PreviewData.runtime(.kimi, snapshot: PreviewData.kimi(weekRemaining: 66)),
            .deepseek: PreviewData.runtime(.deepseek, snapshot: PreviewData.deepseek(total: "62.47")),
        ]
        let state = EngineState(
            providers: providers,
            overview: GlobalOverview.compute(
                snapshots: providers.compactMapValues(\.snapshot),
                evaluator: StatusEvaluator(),
                now: Date()
            )
        )
        #expect(label(state) == "全局最紧剩余 66%,Kimi 周窗口;最差状态:全部正常")
    }
}
