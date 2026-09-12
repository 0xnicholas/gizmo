import Foundation
import Testing
@testable import UsageMonitorCore

@Suite("全局汇总(图标数字与总览条口径)")
struct GlobalOverviewTests {
    let evaluator = StatusEvaluator()

    @Test("图标数字取全部 provider 的 plan-window 最低剩余占比")
    func iconPercentUsesLowestFraction() {
        let snapshots: [Provider: Snapshot] = [
            .glm: Fixture.snapshot(provider: .glm, windows: [
                Fixture.planWindow(limit: 12_000, remaining: 6_000, label: "5 小时窗"),
                Fixture.planWindow(limit: 60_000, remaining: 45_000, label: "7 天窗"),
            ]),
            .kimi: Fixture.snapshot(provider: .kimi, windows: [
                Fixture.planWindow(limit: 100, remaining: 36, label: "周窗口", unit: "请求"),
            ]),
        ]
        let overview = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator)
        #expect(overview.iconPercent == 36)
        #expect(overview.tightest?.provider == .kimi)
        #expect(overview.tightest?.windowLabel == "周窗口")
    }

    @Test("图标数字四舍五入,最低 1%,真 0 显示 0")
    func iconPercentRounding() {
        func percent(remaining: Double, limit: Double) -> Int? {
            let overview = GlobalOverview.compute(
                snapshots: [.glm: Fixture.snapshot(provider: .glm, windows: [
                    Fixture.window(kind: .planWindow, limit: Int(limit), used: 0, remaining: Int(remaining)),
                ])],
                evaluator: evaluator
            )
            return overview.iconPercent
        }
        #expect(percent(remaining: 6_450, limit: 10_000) == 65)  // 64.5% 向上取整
        #expect(percent(remaining: 4, limit: 10_000) == 1)       // 0.04% → 最低 1%
        #expect(percent(remaining: 0, limit: 10_000) == 0)       // 真 0 显示 0
    }

    @Test("只有 DeepSeek(无任何窗口)时图标为「—」,但状态仍可拉低")
    func noWindowsMeansDash() {
        let snapshots: [Provider: Snapshot] = [
            .deepseek: Fixture.snapshot(provider: .deepseek, balances: [Fixture.balance(.topUp, "3.00")]),
        ]
        let overview = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator)
        #expect(overview.iconPercent == nil)
        #expect(overview.tightest == nil)
        #expect(overview.worstStatus == .critical)
    }

    @Test("颜色 = 全局最差状态(含 DeepSeek 余额分界)")
    func worstStatusIncludesBalanceProviders() {
        let snapshots: [Provider: Snapshot] = [
            .glm: Fixture.snapshot(provider: .glm, windows: [
                Fixture.planWindow(limit: 10_000, remaining: 6_400),
            ]),
            .deepseek: Fixture.snapshot(provider: .deepseek, balances: [Fixture.balance(.topUp, "30.00")]),
        ]
        let overview = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator)
        #expect(overview.iconPercent == 64)
        #expect(overview.worstStatus == .low)
    }

    @Test("没有任何快照 → 无数字、无状态")
    func emptyState() {
        let overview = GlobalOverview.compute(snapshots: [:], evaluator: evaluator)
        #expect(overview.iconPercent == nil)
        #expect(overview.worstStatus == nil)
        #expect(overview.snapshotCount == 0)
    }

    @Test("并列最紧时按 provider 枚举顺序取之(结果稳定)")
    func tieBreaksDeterministically() {
        let equal = Fixture.planWindow(limit: 100, remaining: 50)
        let snapshots: [Provider: Snapshot] = [
            .glm: Fixture.snapshot(provider: .glm, windows: [equal]),
            .kimi: Fixture.snapshot(provider: .kimi, windows: [equal]),
        ]
        let overview = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator)
        #expect(overview.tightest?.provider == .kimi)  // Provider.allCases 顺序中 kimi 先于 glm
    }
}
