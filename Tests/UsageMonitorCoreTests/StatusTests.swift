import Foundation
import Testing
@testable import UsageMonitorCore

@Suite("status 阈值与余额分界")
struct StatusTests {
    let evaluator = StatusEvaluator()

    @Test("plan-window 剩余占比边界:9.9% 临界 / 10% 偏低 / 29.9% 偏低 / 30% 正常")
    func planWindowBoundaries() {
        func status(remaining: Int) -> ProviderStatus {
            evaluator.status(for: Fixture.snapshot(
                provider: .glm,
                windows: [Fixture.planWindow(limit: 10_000, remaining: remaining)]
            ))
        }
        #expect(status(remaining: 990) == .critical)   // 9.9%
        #expect(status(remaining: 1_000) == .low)      // 10%
        #expect(status(remaining: 2_990) == .low)      // 29.9%
        #expect(status(remaining: 3_000) == .normal)   // 30%
    }

    @Test("取全部 plan-window 的最低值")
    func lowestPlanWindowWins() {
        let snapshot = Fixture.snapshot(provider: .glm, windows: [
            Fixture.planWindow(limit: 60_000, remaining: 30_000, label: "7 天窗"),
            Fixture.planWindow(limit: 12_000, remaining: 600, label: "5 小时窗"),
        ])
        #expect(evaluator.status(for: snapshot) == .critical)
    }

    @Test("频限窗不参与 status 推导")
    func rateLimitExcluded() {
        let snapshot = Fixture.snapshot(provider: .kimi, windows: [
            Fixture.planWindow(limit: 100, remaining: 50, label: "日窗口", unit: "会话"),
            Fixture.rateLimitWindow(limit: 100, remaining: 1),
        ])
        #expect(evaluator.status(for: snapshot) == .normal)
    }

    @Test("DeepSeek 余额分界:¥9.99 临界 / ¥10 偏低 / ¥49.99 偏低 / ¥50 正常")
    func deepseekBalanceBoundaries() {
        func status(total: String) -> ProviderStatus {
            evaluator.status(for: Fixture.snapshot(
                provider: .deepseek,
                balances: [Fixture.balance(.topUp, total)]
            ))
        }
        #expect(status(total: "9.99") == .critical)
        #expect(status(total: "10") == .low)
        #expect(status(total: "49.99") == .low)
        #expect(status(total: "50") == .normal)
    }

    @Test("DeepSeek 充值 + 赠送合计参与档位")
    func deepseekSumsBalances() {
        let snapshot = Fixture.snapshot(provider: .deepseek, balances: [
            Fixture.balance(.topUp, "6.00"),
            Fixture.balance(.granted, "4.00"),
        ])
        #expect(evaluator.status(for: snapshot) == .low)  // 合计 ¥10
    }

    @Test("is_available=false 直接临界,与余额无关")
    func unavailableIsCritical() {
        let snapshot = Fixture.snapshot(
            provider: .deepseek,
            balances: [Fixture.balance(.topUp, "999.00")],
            accountAvailable: false
        )
        #expect(evaluator.status(for: snapshot) == .critical)
    }

    @Test("多币种:主币种为 CNY,其余币种不参与 DeepSeek 档位")
    func multiCurrencyUsesCNY() {
        let snapshot = Fixture.snapshot(provider: .deepseek, balances: [
            Fixture.balance(.topUp, "8.00", currency: "CNY"),
            Fixture.balance(.topUp, "1000.00", currency: "USD"),
        ])
        #expect(snapshot.totalBalance(currency: "CNY") == Decimal(string: "8.00"))
        #expect(evaluator.status(for: snapshot) == .critical)
    }

    @Test("无窗口且无余额 → 正常(无告警依据)")
    func emptySnapshotIsNormal() {
        #expect(evaluator.status(for: Fixture.snapshot(provider: .kimi)) == .normal)
    }

    @Test("limit 为 0 的窗口不参与判定")
    func zeroLimitIgnored() {
        let snapshot = Fixture.snapshot(provider: .glm, windows: [
            Fixture.window(kind: .planWindow, limit: 0, used: 0, remaining: 0),
        ])
        #expect(evaluator.status(for: snapshot) == .normal)
    }

    @Test("阈值参数化:换一份 Thresholds 即改档位(余额分界同理)")
    func thresholdsAreInjectable() {
        #expect(StatusEvaluator().status(forBalance: Decimal(15)) == .low)  // 默认为 ¥10–50 区间

        let custom = StatusEvaluator(thresholds: Thresholds(
            criticalRemainingFraction: 0.05,
            lowRemainingFraction: 0.50,
            deepseekCriticalBalance: 20,
            deepseekLowBalance: 100
        ))
        #expect(custom.status(forBalance: Decimal(15)) == .critical)
        #expect(custom.status(forBalance: Decimal(50)) == .low)
        #expect(custom.status(forBalance: Decimal(100)) == .normal)
        #expect(custom.status(forRemainingFraction: 0.08) == .low)      // 默认阈值下为临界
        #expect(custom.status(forRemainingFraction: 0.05) == .low)      // 等于临界阈值 → 下一档
        #expect(custom.status(forRemainingFraction: 0.04) == .critical)
        #expect(custom.status(forRemainingFraction: 0.50) == .normal)
    }

    @Test("worst 取更差者")
    func worstOf() {
        #expect(ProviderStatus.worst(.normal, .critical) == .critical)
        #expect(ProviderStatus.worst(.low, .normal) == .low)
        #expect(ProviderStatus.worst(.low, .low) == .low)
    }
}
