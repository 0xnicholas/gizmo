import Foundation
import Testing
@testable import UsageMonitorCore

/// 到期判定(#54):planValidity 与 now 的纯求值,三态 + 来源 + 观测时刻。
/// 到期不进健康状态档(「还适不适用」≠「还够不够用」),陈旧是展示属性不是第四态。
@Suite("planState 到期判定")
struct PlanStateTests {
    /// 实测区间末端:2026-10-15 10:00:00 +08:00。
    private static let periodEnd = Date(timeIntervalSince1970: 1_792_029_600)

    private func state(
        provider: Provider = .glm,
        validity: PlanValidity? = Fixture.validity(),
        observedAt: Date? = nil,
        snapshotFetchedAt: Date = Fixture.epoch,
        now: Date
    ) -> PlanState {
        var validity = validity
        validity?.observedAt = observedAt
        let snapshot = Fixture.snapshot(
            provider: provider,
            planValidity: validity,
            fetchedAt: snapshotFetchedAt
        )
        return PlanState.evaluate(provider: provider, snapshot: snapshot, manualExpiry: nil, now: now)
    }

    @Test("三态推导:区间内 active(带 autoRenew 与观测时刻);无 planValidity → unknown")
    func threeStates() {
        let active = state(now: Self.periodEnd.addingTimeInterval(-86_400))
        #expect(active == .active(
            validUntil: Self.periodEnd,
            autoRenew: false,
            observedAt: Fixture.epoch
        ))

        let none = state(validity: nil, now: Fixture.epoch)
        #expect(none == .unknown)
    }

    @Test("边界:now == validUntil 当刻即 expired;早一秒 active")
    func expiryBoundary() {
        #expect(state(now: Self.periodEnd) == .expired(
            validUntil: Self.periodEnd,
            observedAt: Fixture.epoch
        ))
        #expect(state(now: Self.periodEnd).isExpired)
        #expect(!state(now: Self.periodEnd.addingTimeInterval(-1)).isExpired)
        #expect(!state(validity: nil, now: Fixture.epoch).isExpired, "unknown 不灰")
        #expect(state(now: Self.periodEnd.addingTimeInterval(-1)) == .active(
            validUntil: Self.periodEnd,
            autoRenew: false,
            observedAt: Fixture.epoch
        ))
    }

    @Test("expired 不携带 autoRenew(续订事实对已到期的结论无贡献)")
    func expiredOmitsAutoRenew() {
        if case .expired(let validUntil, let observedAt) = state(now: Self.periodEnd) {
            #expect(validUntil == Self.periodEnd)
            #expect(observedAt == Fixture.epoch)
        } else {
            Issue.record("应判 expired,得到 \(state(now: Self.periodEnd))")
        }
    }

    @Test("DeepSeek 恒 unknown:即使快照被误挂有效期也不做到期断言(余额型无套餐窗口)")
    func deepseekAlwaysUnknown() {
        #expect(state(provider: .deepseek, now: Self.periodEnd) == .unknown)
        #expect(state(provider: .deepseek, now: Fixture.epoch) == .unknown)
    }

    @Test("Kimi 无来源且无手动声明 → unknown(与手动标记前一致)")
    func kimiWithoutSourceIsUnknown() {
        #expect(state(provider: .kimi, validity: nil, now: Fixture.epoch) == .unknown)
    }

    @Test("无快照(从未成功)→ unknown")
    func missingSnapshotIsUnknown() {
        #expect(PlanState.evaluate(provider: .glm, snapshot: nil, manualExpiry: nil, now: Fixture.epoch) == .unknown)
    }

    @Test("观测时刻:优先取有效期自身的 observedAt;缺失时回退快照 fetchedAt(旧缓存兼容)")
    func observedAtFallback() {
        // 有效期自带观测时刻(跨订阅分片失败保留时不动)→ 用它
        let own = state(observedAt: Fixture.epoch.addingTimeInterval(-3_600), now: Self.periodEnd)
        #expect(own == .expired(validUntil: Self.periodEnd, observedAt: Fixture.epoch.addingTimeInterval(-3_600)))

        // 旧缓存文件(#54 前)没有 observedAt → 回退快照 fetchedAt
        let legacy = state(snapshotFetchedAt: Fixture.epoch.addingTimeInterval(-120), now: Self.periodEnd)
        #expect(legacy == .expired(validUntil: Self.periodEnd, observedAt: Fixture.epoch.addingTimeInterval(-120)))
    }

    @Test("阈值默认:提前提醒 3 天;到期结论陈旧阈值 = 2× 默认轮询周期(60 分钟)")
    func thresholdDefaults() {
        let thresholds = Thresholds()
        #expect(thresholds.expiryReminderDays == 3)
        #expect(thresholds.expiryStalenessThreshold == 2 * thresholds.refreshInterval)
        #expect(thresholds.expiryStalenessThreshold == 3_600)
    }
}
