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
