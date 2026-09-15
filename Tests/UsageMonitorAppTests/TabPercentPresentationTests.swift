import Foundation
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// tab 速览数字口径(P2-5,B,#43):tab 文本追加各家 plan-window 最低剩余%——
/// 数字与焦点卡窗口行、总览大数字同源同口径(Percent.display,频限窗不参与);
/// 颜色随该家 status(口径乙同型:窗口家色档 = 最紧窗自身色档;DeepSeek 无窗
/// 「彩色 —」由余额色档给色);无快照家灰「—」。
@Suite("tab 速览数字(P2-5)")
struct TabPercentPresentationTests {
    private func figure(_ runtime: ProviderRuntimeState) -> TabPercentPresentation {
        TabPercentPresentation(runtime: runtime)
    }

    @Test("窗口家取 plan-window 最低剩余%:GLM 双窗取 7 天窗 65%,非 5 小时窗 95%")
    func glmPicksLowestPlanWindow() {
        let presentation = figure(PreviewData.runtime(.glm, snapshot: PreviewData.glm(weeklyRemaining: 39_000)))
        #expect(presentation.text == "65%")
        #expect(presentation.colorStatus == .normal)
    }

    @Test("频限窗不参与:Kimi 显周窗 66% 而非频限 90%")
    func kimiIgnoresRateLimitWindow() {
        let presentation = figure(PreviewData.runtime(.kimi, snapshot: PreviewData.kimi(weekRemaining: 66)))
        #expect(presentation.text == "66%")
        #expect(presentation.colorStatus == .normal)
    }

    @Test("色档随数字:同家 tab 取色档 = 该家 status(偏低黄、临界红)")
    func tierFollowsFigure() {
        let low = figure(PreviewData.runtime(.glm, snapshot: PreviewData.glm(weeklyRemaining: 12_000)))
        #expect(low.text == "20%")
        #expect(low.colorStatus == .low)
        let critical = figure(PreviewData.runtime(.glm, snapshot: PreviewData.glm(weeklyRemaining: 3_000)))
        #expect(critical.text == "5%")
        #expect(critical.colorStatus == .critical)
    }

    @Test("DeepSeek 有快照无窗口:「—」由余额档给色(彩色 —,口径乙同型)")
    func deepseekSnapshotWithoutWindows() {
        let critical = figure(PreviewData.runtime(.deepseek, snapshot: PreviewData.deepseek(total: "8.20")))
        #expect(critical.text == "—")
        #expect(critical.colorStatus == .critical)
        let normal = figure(PreviewData.runtime(.deepseek, snapshot: PreviewData.deepseek(total: "62.47")))
        #expect(normal.text == "—")
        #expect(normal.colorStatus == .normal)
    }

    @Test("无快照:灰「—」")
    func noSnapshotGrayDash() {
        let presentation = figure(PreviewData.runtime(.kimi, snapshot: nil))
        #expect(presentation.text == "—")
        #expect(presentation.colorStatus == nil)
    }

    // MARK: - 到期态(#54)

    @Test("到期家:tab 换「已到期」,取色灰(nil)——速览位不给已失效的数字留位置")
    func expiredShowsExpiredLabel() {
        let expired = PreviewData.glm(validity: PreviewData.validity(untilDays: -2, fromDays: -32))
        let presentation = TabPercentPresentation(runtime: PreviewData.runtime(.glm, snapshot: expired), now: Date())
        #expect(presentation.text == "已到期")
        #expect(presentation.colorStatus == nil)
    }

    @Test("到期边界:now == 有效期末端当刻即「已到期」")
    func expiryBoundaryIsImmediate() {
        let now = Date()
        let validity = PlanValidity(
            validFrom: now.addingTimeInterval(-30 * 86_400),
            validUntil: now,
            status: "VALID",
            autoRenew: false
        )
        let snapshot = PreviewData.glm(validity: validity)
        #expect(TabPercentPresentation(runtime: PreviewData.runtime(.glm, snapshot: snapshot), now: now).text == "已到期")
        #expect(TabPercentPresentation(runtime: PreviewData.runtime(.glm, snapshot: snapshot), now: now.addingTimeInterval(-1)).text == "27%")
    }

    @Test("无到期断言的家不灰:未到期照常显百分比与色档;无有效期信息照旧「—」/百分比")
    func unknownStaysUnaffected() {
        let active = figure(PreviewData.runtime(.glm, snapshot: PreviewData.glm()))
        #expect(active.text == "27%")
        #expect(active.colorStatus == .low)  // 15_929/60_000 = 26.5%:照常的色档,不受到期口径影响

        let noValidity = PreviewData.glm(validity: nil)
        let none = figure(PreviewData.runtime(.glm, snapshot: noValidity))
        #expect(none.text == "27%", "无有效期信息 = 无到期断言,tab 照常")
    }

    @Test("凭据问题优先于到期:失效家不显「已到期」(卡片回到既有凭据占位,tab 不做到期断言)")
    func credentialBeatsExpiry() {
        let expired = PreviewData.glm(validity: PreviewData.validity(untilDays: -2, fromDays: -32))
        let presentation = TabPercentPresentation(
            runtime: PreviewData.runtime(.glm, snapshot: expired, credential: .invalid),
            now: Date()
        )
        #expect(presentation.text != "已到期")
    }

    @Test("与总览大数字同口径:最紧家的 tab 数字 = 全局数字;他家各自独立成立")
    func consistentWithGlobalFigure() {
        let state = PreviewData.overviewState()
        let global = GlobalPercentPresentation(state: state, scheme: .light).text
        // overviewState 最紧家 = GLM 7 天窗(15_929/60_000 → 27%):tab 与全局两处不打架。
        #expect(figure(state.provider(.glm)).text == global)
        #expect(figure(state.provider(.glm)).text == "27%")
        #expect(figure(state.provider(.kimi)).text == "66%")
        // DeepSeek 持快照无窗:tab「—」与全局口径(无窗家不贡献数字)一致。
        #expect(figure(state.provider(.deepseek)).text == "—")
    }
}
