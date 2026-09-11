import Foundation
import Testing
@testable import UsageMonitorCore

@Suite("百分比口径一致")
struct PercentTests {
    @Test("四舍五入,最低 1%,真 0 显示 0")
    func displayRules() {
        #expect(Percent.display(0.645) == 65)
        #expect(Percent.display(0.0004) == 1)   // 0.04% → 最低 1%
        #expect(Percent.display(0) == 0)
        #expect(Percent.display(-0.1) == 0)
        #expect(Percent.rounded(0.0004) == 0)   // 中性场景不钳制
    }

    @Test("图标数字与总览条「全局最紧」同源(用户故事 18)")
    func iconMatchesOverviewBar() {
        let evaluator = StatusEvaluator()
        let snapshots: [Provider: Snapshot] = [
            .glm: Fixture.snapshot(provider: .glm, windows: [
                Fixture.planWindow(limit: 10_000, remaining: 30, label: "5 小时窗"),
            ]),
        ]
        let overview = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator)
        let tightest = try! #require(overview.tightest)
        #expect(overview.iconPercent == tightest.displayPercent)
        #expect(tightest.displayPercent == 1)  // 0.3% → 图标与总览条都显示 1%
    }
}
