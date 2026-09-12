import Foundation
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// 图标/总览大数字的取色口径乙(IC-4+IC-5,#41):颜色随数字口径——
/// 有额度窗口时 = 最紧窗所属 provider 的 status(即最紧窗自身档位);
/// 无任何窗口(DeepSeek-only / 首刷未回)时 = 持快照家的档位给色「彩色 —」;
/// 全无快照 = nil(灰「—」)。DeepSeek 余额临界不再把数字拉红,
/// 由临界通知与总览条(圆点/alertLine 仍消费 worstStatus)兜底。
@Suite("全局数字取色口径乙(IC-4+IC-5)")
struct GlobalPercentColorStatusTests {
    private static let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func runtime(
        _ provider: Provider,
        snapshot: Snapshot?,
        credential: CredentialState = .configured
    ) -> ProviderRuntimeState {
        PreviewData.runtime(provider, snapshot: snapshot, credential: credential)
    }

    private func overview(
        tightest: GlobalOverview.Tightest?,
        worstStatus: ProviderStatus?
    ) -> GlobalOverview {
        GlobalOverview(tightest: tightest, worstStatus: worstStatus, snapshotCount: 1)
    }

    private func colorStatus(_ state: EngineState) -> ProviderStatus? {
        GlobalPercentPresentation(state: state, scheme: .light, now: Self.now).colorStatus
    }

    /// DeepSeek 临界(余额 8.20)+ GLM 7 天窗 65%(健康):数字绿,不再红。
    @Test("DeepSeek 临界不牵连窗口数字:绿 65%(旧口径「红 65%」消灭)")
    func deepseekCriticalDoesNotTaintWindowFigure() {
        let state = EngineState(
            providers: [
                .glm: runtime(.glm, snapshot: PreviewData.glm(weeklyRemaining: 39_000)),
                .kimi: runtime(.kimi, snapshot: PreviewData.kimi()),
                .deepseek: runtime(.deepseek, snapshot: PreviewData.deepseek(total: "8.20")),
            ],
            overview: overview(
                tightest: .init(
                    provider: .glm, windowLabel: "7 天窗", unit: "积分",
                    limit: 60_000, remaining: 39_000, fraction: 0.65, resetAt: nil
                ),
                worstStatus: .critical // 全局最差 = DeepSeek 余额档(旧口径的红色来源)
            )
        )
        let presentation = GlobalPercentPresentation(state: state, scheme: .light, now: Self.now)
        #expect(presentation.text == "65%")
        #expect(presentation.colorStatus == .normal)
    }

    @Test("最紧窗自身档位偏低 → 数字黄(纯窗口态不回归)")
    func windowTierDrivesColor() {
        let state = EngineState(
            providers: [
                .glm: runtime(.glm, snapshot: PreviewData.glm(weeklyRemaining: 12_000)),
                .deepseek: runtime(.deepseek, snapshot: PreviewData.deepseek(total: "62.47")),
            ],
            overview: overview(
                tightest: .init(
                    provider: .glm, windowLabel: "7 天窗", unit: "积分",
                    limit: 60_000, remaining: 12_000, fraction: 0.2, resetAt: nil
                ),
                worstStatus: .low
            )
        )
        #expect(colorStatus(state) == .low)
    }

    @Test("最紧窗自身档位临界 → 数字红(纯窗口态不回归,临界档单测锁定)")
    func windowCriticalTierDrivesColor() {
        let state = EngineState(
            providers: [
                .glm: runtime(.glm, snapshot: PreviewData.glm(weeklyRemaining: 3_000)),
            ],
            overview: overview(
                tightest: .init(
                    provider: .glm, windowLabel: "7 天窗", unit: "积分",
                    limit: 60_000, remaining: 3_000, fraction: 0.05, resetAt: nil
                ),
                worstStatus: .critical
            )
        )
        #expect(colorStatus(state) == .critical)
    }

    /// DeepSeek-only 临界:无任何 plan-window,余额档给色的「彩色 —」。
    @Test("DeepSeek-only 临界:彩色「—」(余额档给色,不再永久灰)")
    func deepseekOnlyCriticalGivesColoredDash() {
        let state = EngineState(
            providers: [
                .glm: runtime(.glm, snapshot: nil, credential: .missing),
                .kimi: runtime(.kimi, snapshot: nil, credential: .missing),
                .deepseek: runtime(.deepseek, snapshot: PreviewData.deepseek(total: "8.20")),
            ],
            overview: overview(tightest: nil, worstStatus: .critical)
        )
        let presentation = GlobalPercentPresentation(state: state, scheme: .light, now: Self.now)
        #expect(presentation.text == "—")
        #expect(presentation.colorStatus == .critical)
    }

    @Test("DeepSeek-only 正常:彩色「—」同样成立(绿档)")
    func deepseekOnlyNormalColoredDash() {
        let state = EngineState(
            providers: [.deepseek: runtime(.deepseek, snapshot: PreviewData.deepseek(total: "62.47"))],
            overview: overview(tightest: nil, worstStatus: .normal)
        )
        #expect(colorStatus(state) == .normal)
    }

    @Test("全无快照:灰「—」(全新安装口径不变)")
    func noSnapshotsStaysGray() {
        let state = EngineState(providers: [:], overview: GlobalOverview(tightest: nil, worstStatus: nil, snapshotCount: 0))
        let presentation = GlobalPercentPresentation(state: state, scheme: .light, now: Self.now)
        #expect(presentation.text == "—")
        #expect(presentation.colorStatus == nil)
    }
}
