import Foundation
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// 图标数字的陈旧标记(IC-3,#33):最紧窗所属 provider 自己的 `lastSuccessAt`
/// 距 now 超过 2× 轮询间隔(默认 30 分钟 → 60 分钟)时降透明度;
/// 不用全局 lastUpdatedAt(会被别家成功刷新冲掉)。
@Suite("全局结论数字的陈旧标记(IC-3)")
struct GlobalPercentStalenessTests {
    private static let now = Date(timeIntervalSince1970: 1_789_000_000)
    private static let staleThreshold: TimeInterval = 2 * Thresholds().refreshInterval

    /// GLM 持最紧窗(7 天窗 20%);别家 lastSuccessAt 可独立设置,验证不被冲掉。
    private func state(glmLastSuccess: Date?, kimiLastSuccess: Date? = nil) -> EngineState {
        func runtime(_ provider: Provider, lastSuccess: Date?) -> ProviderRuntimeState {
            var runtime = ProviderRuntimeState(provider: provider)
            runtime.lastSuccessAt = lastSuccess
            return runtime
        }

        let overview = GlobalOverview(
            tightest: .init(
                provider: .glm,
                windowLabel: "7 天窗",
                unit: "积分",
                limit: 60_000,
                remaining: 12_000,
                fraction: 0.2,
                resetAt: nil
            ),
            worstStatus: .low,
            snapshotCount: 1
        )
        return EngineState(
            providers: [
                .glm: runtime(.glm, lastSuccess: glmLastSuccess),
                .kimi: runtime(.kimi, lastSuccess: kimiLastSuccess),
                .deepseek: runtime(.deepseek, lastSuccess: nil),
            ],
            overview: overview
        )
    }

    private func isStale(glmLastSuccess: Date?, kimiLastSuccess: Date? = nil) -> Bool {
        GlobalPercentPresentation(
            state: state(glmLastSuccess: glmLastSuccess, kimiLastSuccess: kimiLastSuccess),
            scheme: .light,
            now: Self.now
        ).isStale
    }

    @Test("超 60 分钟(2× 轮询间隔)带陈旧标记")
    func staleBeyondThreshold() {
        #expect(isStale(glmLastSuccess: Self.now.addingTimeInterval(-Self.staleThreshold - 60)))
    }

    @Test("未超不带;整 60 分钟不算超过")
    func freshWithinThreshold() {
        #expect(!isStale(glmLastSuccess: Self.now.addingTimeInterval(-Self.staleThreshold)))
        #expect(!isStale(glmLastSuccess: Self.now.addingTimeInterval(-Self.staleThreshold + 60)))
        #expect(!isStale(glmLastSuccess: Self.now.addingTimeInterval(-5 * 60)))
    }

    @Test("不被别家成功刷新冲掉:最紧家 90 分钟前、别家 1 分钟前仍陈旧")
    func notResetByOtherProvidersSuccess() {
        #expect(isStale(
            glmLastSuccess: Self.now.addingTimeInterval(-90 * 60),
            kimiLastSuccess: Self.now.addingTimeInterval(-60)
        ))
    }

    @Test("最紧家 lastSuccessAt 未知时不误标")
    func unknownLastSuccessNotMarked() {
        #expect(!isStale(glmLastSuccess: nil))
    }

    @Test("无窗口数据(灰「—」)不判陈旧;数字文案不受陈旧影响")
    func noWindowDataNotStaleAndTextStable() {
        var state = EngineState(providers: [:])
        state.overview = GlobalOverview(tightest: nil, worstStatus: nil, snapshotCount: 0)
        let gray = GlobalPercentPresentation(state: state, scheme: .light, now: Self.now)
        #expect(!gray.isStale)
        #expect(gray.text == "—")

        let staleFigure = GlobalPercentPresentation(
            state: self.state(glmLastSuccess: Self.now.addingTimeInterval(-90 * 60)),
            scheme: .light,
            now: Self.now
        )
        #expect(staleFigure.text == "20%")
    }
}
