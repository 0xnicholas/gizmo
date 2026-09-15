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
        let overview = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator, now: Fixture.epoch)
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
                evaluator: evaluator,
                now: Fixture.epoch
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
        let overview = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator, now: Fixture.epoch)
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
        let overview = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator, now: Fixture.epoch)
        #expect(overview.iconPercent == 64)
        #expect(overview.worstStatus == .low)
    }

    @Test("没有任何快照 → 无数字、无状态")
    func emptyState() {
        let overview = GlobalOverview.compute(snapshots: [:], evaluator: evaluator, now: Fixture.epoch)
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
        let overview = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator, now: Fixture.epoch)
        #expect(overview.tightest?.provider == .kimi)  // Provider.allCases 顺序中 kimi 先于 glm
    }
}

/// 到期退出全局口径(#56):到期家不再充当任何全局结论——不进图标数字、
/// 不进「全局最紧」、不进全局最差状态;但由 `expiredProviders` 承认出来,
/// 供总览条「已到期:」行与图标 a11y 讲清「—」的来历。
@Suite("全局汇总的到期剔除(#56)")
struct GlobalOverviewExpiryTests {
    let evaluator = StatusEvaluator()

    private func expiredPlan(validUntil: Date = Fixture.epoch) -> PlanState {
        .expired(validUntil: validUntil, observedAt: Fixture.epoch)
    }

    @Test("到期家退出最紧/最差/图标数字;未到期家照常参与")
    func expiredProviderExitsGlobalConclusions() {
        let snapshots: [Provider: Snapshot] = [
            .glm: Fixture.snapshot(provider: .glm, windows: [
                Fixture.planWindow(limit: 60_000, remaining: 1_000, label: "7 天窗"),
            ]),
            .kimi: Fixture.snapshot(provider: .kimi, windows: [
                Fixture.planWindow(limit: 100, remaining: 66, label: "周窗口", unit: "请求"),
            ]),
        ]
        // 对照(不剔除时):GLM 是最紧且把全局最差拉到临界
        let baseline = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator, planStates: [:])
        #expect(baseline.tightest?.provider == .glm)
        #expect(baseline.worstStatus == .critical)

        let overview = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator, planStates: [.glm: expiredPlan()])
        #expect(overview.tightest?.provider == .kimi)
        #expect(overview.iconPercent == 66)
        #expect(overview.worstStatus == .normal, "死档不决定全局最差")
        #expect(overview.expiredProviders == [.glm])
    }

    @Test("多家到期:expiredProviders 按枚举序稳定;余额档(DeepSeek)同样被剔除")
    func expiredListIsDeterministicAndCoversBalanceProviders() {
        let snapshots: [Provider: Snapshot] = [
            .glm: Fixture.snapshot(provider: .glm, windows: [Fixture.planWindow(limit: 60_000, remaining: 1_000)]),
            .kimi: Fixture.snapshot(provider: .kimi, windows: [Fixture.planWindow(limit: 100, remaining: 66, label: "周窗口", unit: "请求")]),
            .deepseek: Fixture.snapshot(provider: .deepseek, balances: [Fixture.balance(.topUp, "8.20")]),
        ]
        let overview = GlobalOverview.compute(
            snapshots: snapshots,
            evaluator: evaluator,
            planStates: [.glm: expiredPlan(), .deepseek: expiredPlan()]
        )
        #expect(overview.expiredProviders == [.deepseek, .glm], "按 Provider.allCases 序")
        #expect(overview.worstStatus == .normal, "DeepSeek 余额临界也被到期剔除")
        #expect(overview.tightest?.provider == .kimi)
    }

    @Test("全部到期:无最紧、无最差、图标「—」")
    func allExpiredMeansNoGlobalConclusions() {
        let snapshots: [Provider: Snapshot] = [
            .glm: Fixture.snapshot(provider: .glm, windows: [Fixture.planWindow(limit: 60_000, remaining: 1_000)]),
            .kimi: Fixture.snapshot(provider: .kimi, windows: [Fixture.planWindow(limit: 100, remaining: 5, label: "周窗口", unit: "请求")]),
        ]
        let overview = GlobalOverview.compute(
            snapshots: snapshots,
            evaluator: evaluator,
            planStates: [.glm: expiredPlan(), .kimi: expiredPlan()]
        )
        #expect(overview.tightest == nil)
        #expect(overview.worstStatus == nil)
        #expect(overview.iconPercent == nil)
        #expect(overview.expiredProviders == [.kimi, .glm])
        #expect(overview.snapshotCount == 2, "持快照数不变——到期是退出结论,不是丢数据")
    }

    @Test("now 求值入口:快照 planValidity 已过末端 → 剔除;未过 → 照常")
    func nowEntryEvaluatesPlanState() {
        let snapshots: [Provider: Snapshot] = [
            .glm: Fixture.snapshot(
                provider: .glm,
                windows: [Fixture.planWindow(limit: 60_000, remaining: 1_000)],
                planValidity: Fixture.validity(
                    validFrom: Fixture.epoch.addingTimeInterval(-40 * 86_400),
                    validUntil: Fixture.epoch.addingTimeInterval(-2 * 86_400)
                )
            ),
        ]
        let expired = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator, now: Fixture.epoch)
        #expect(expired.expiredProviders == [.glm])
        #expect(expired.tightest == nil)

        let active = GlobalOverview.compute(
            snapshots: [
                .glm: Fixture.snapshot(
                    provider: .glm,
                    windows: [Fixture.planWindow(limit: 60_000, remaining: 1_000)],
                    planValidity: Fixture.validity(
                        validFrom: Fixture.epoch.addingTimeInterval(-30 * 86_400),
                        validUntil: Fixture.epoch.addingTimeInterval(30 * 86_400)
                    )
                )],
            evaluator: evaluator,
            now: Fixture.epoch
        )
        #expect(active.expiredProviders.isEmpty)
        #expect(active.iconPercent == 2)
    }

    @Test("DeepSeek 恒 unknown:快照即使带 planValidity 也不被剔除(余额型家不做到期断言)")
    func deepseekNeverExpiresThroughEvaluation() {
        let snapshots: [Provider: Snapshot] = [
            .deepseek: Fixture.snapshot(
                provider: .deepseek,
                balances: [Fixture.balance(.topUp, "8.20")],
                planValidity: Fixture.validity(
                    validFrom: Fixture.epoch.addingTimeInterval(-40 * 86_400),
                    validUntil: Fixture.epoch.addingTimeInterval(-2 * 86_400)
                )
            ),
        ]
        let overview = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator, now: Fixture.epoch)
        #expect(overview.expiredProviders.isEmpty)
        #expect(overview.worstStatus == .critical, "余额档照常参与全局最差")
    }

    @Test("unknown(无有效期信息)的家照常参与——不因无来源被剔除")
    func unknownPlanStaysInConclusions() {
        let snapshots: [Provider: Snapshot] = [
            .glm: Fixture.snapshot(
                provider: .glm,
                windows: [Fixture.planWindow(limit: 60_000, remaining: 1_000)],
                planValidity: nil
            ),
        ]
        let overview = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator, planStates: [.glm: .unknown])
        #expect(overview.tightest?.provider == .glm)
        #expect(overview.expiredProviders.isEmpty)
    }
}
