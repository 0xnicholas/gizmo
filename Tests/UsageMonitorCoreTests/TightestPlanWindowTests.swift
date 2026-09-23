import Foundation
import Testing
@testable import UsageMonitorCore

/// 单家最紧 plan-window 的取数(#59 评审后收进 Core):全部 plan-window 中剩余占比
/// 最低者(并列取先出现者),频限窗不参与——与 status 判定同一范围。
/// status 推导 / tab 速览 / 菜单栏图标 / 全局最紧四处共用这一处口径。
@Suite("单家最紧 plan-window 取数")
struct TightestPlanWindowTests {
    @Test("取剩余占比最低者,不看绝对剩余")
    func picksLowestFraction() {
        // 绝对剩余更少的是 5 小时窗(6,000 < 12,000),但占比更紧的是 7 天窗
        // (20% < 50%)——占比是唯一口径,不拿绝对数比大小。
        let snapshot = Fixture.snapshot(provider: .glm, windows: [
            Fixture.planWindow(limit: 60_000, remaining: 12_000, label: "7 天窗"),
            Fixture.planWindow(limit: 12_000, remaining: 6_000, label: "5 小时窗"),
        ])
        #expect(snapshot.tightestPlanWindow?.label == "7 天窗")
        #expect(snapshot.tightestPlanWindow?.remainingFraction == 0.2)
    }

    @Test("并列取先出现者(展示序稳定,不随窗口乱序漂移)")
    func tiesPickFirstOccurrence() {
        let snapshot = Fixture.snapshot(provider: .glm, windows: [
            Fixture.planWindow(limit: 100, remaining: 20, label: "前窗"),
            Fixture.planWindow(limit: 1_000, remaining: 200, label: "后窗"),
        ])
        #expect(snapshot.tightestPlanWindow?.label == "前窗")
    }

    @Test("频限窗不参与;只剩频限窗时 nil")
    func rateLimitWindowsAreIgnored() {
        let snapshot = Fixture.snapshot(provider: .kimi, windows: [
            Fixture.planWindow(limit: 100, remaining: 66, label: "周窗口"),
            Fixture.rateLimitWindow(limit: 100, remaining: 1, label: "频限 · 滚动窗(300 分钟)"),
        ])
        #expect(snapshot.tightestPlanWindow?.label == "周窗口")

        let rateLimitOnly = Fixture.snapshot(provider: .kimi, windows: [
            Fixture.rateLimitWindow(limit: 100, remaining: 1),
        ])
        #expect(rateLimitOnly.tightestPlanWindow == nil)
        #expect(StatusEvaluator().lowestPlanWindowFraction(in: rateLimitOnly) == nil)
    }

    @Test("占比算不出来的窗(limit 非正)跳过,不当成 0% 拖档")
    func uncomputableFractionSkipped() {
        let snapshot = Fixture.snapshot(provider: .glm, windows: [
            Fixture.window(kind: .planWindow, label: "坏窗", limit: 0, used: 0, remaining: 0),
            Fixture.planWindow(limit: 100, remaining: 40, label: "好窗"),
        ])
        #expect(snapshot.tightestPlanWindow?.label == "好窗")
    }

    @Test("无 plan-window 的 provider(DeepSeek)为 nil")
    func noPlanWindowsMeansNil() {
        let snapshot = Fixture.snapshot(provider: .deepseek, balances: [Fixture.balance(.topUp, "62.47")])
        #expect(snapshot.tightestPlanWindow == nil)
    }

    /// 同源断言:status 推导用的占比与最紧窗摘出来的占比必须是同一个数——
    /// 这条是「取数只此一份」的守门测试(两处各扫一遍时最容易在这里分叉)。
    @Test("status 推导的占比 = 最紧窗的占比")
    func statusFractionMatchesTightestWindow() {
        let snapshot = Fixture.snapshot(provider: .glm, windows: [
            Fixture.planWindow(limit: 12_000, remaining: 11_358, label: "5 小时窗"),
            Fixture.planWindow(limit: 60_000, remaining: 12_000, label: "7 天窗"),
        ])
        let fraction = StatusEvaluator().lowestPlanWindowFraction(in: snapshot)
        #expect(fraction == snapshot.tightestPlanWindow?.remainingFraction)
        #expect(StatusEvaluator().status(for: snapshot) == .low)
    }
}
