import Foundation
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// 到期退出口径在呈现层的落点(#56):「已到期:」点名的共享口径(展示序、
/// 凭据门控、全到期判定)与「彩色 —」取色跳过到期家——到期家的档位是死数据,
/// 不给无窗口形态的「—」夸活。
@Suite("到期退出口径的呈现(#56)")
struct ExpiredGlobalExitTests {
    private static let now = Date()

    /// 到期场景共用构造台:overview 与 providers 由同一份快照算出(评审意见:
    /// 视图脚手架只写一遍)。
    private static func makeState(
        glm: ProviderRuntimeState,
        kimi: ProviderRuntimeState,
        deepseek: ProviderRuntimeState
    ) -> EngineState {
        let providers: [Provider: ProviderRuntimeState] = [.glm: glm, .kimi: kimi, .deepseek: deepseek]
        return EngineState(
            providers: providers,
            overview: GlobalOverview.compute(
                snapshots: providers.compactMapValues(\.snapshot),
                evaluator: StatusEvaluator(),
                now: Self.now
            )
        )
    }

    /// GLM 到期(7 天窗 5% 死档),凭据可注入。
    private static func expiredGlm(credential: CredentialState = .configured) -> ProviderRuntimeState {
        PreviewData.runtime(
            .glm,
            snapshot: PreviewData.glm(
                weeklyRemaining: 3_000,
                validity: PreviewData.validity(untilDays: -2, fromDays: -32)
            ),
            credential: credential
        )
    }

    /// Kimi 到期(周窗 5% 死档)。
    private static func expiredKimi() -> ProviderRuntimeState {
        PreviewData.runtime(
            .kimi,
            snapshot: PreviewData.kimi(
                weekRemaining: 5,
                validity: PreviewData.validity(untilDays: -2, fromDays: -32)
            )
        )
    }

    private static let healthyKimi = PreviewData.runtime(
        .kimi, snapshot: PreviewData.kimi(weekRemaining: 66)
    )
    private static let healthyDeepSeek = PreviewData.runtime(
        .deepseek, snapshot: PreviewData.deepseek(total: "62.47")
    )
    private static let unconfigured = PreviewData.runtime(
        .deepseek, snapshot: nil, credential: .missing
    )

    @Test("「已到期:」点名按展示序,凭据失效家不点名(凭据问题优先于到期,归横幅)")
    func expiredNamingUsesDisplayOrderAndCredentialGate() {
        let state = Self.makeState(
            glm: Self.expiredGlm(credential: .invalid),
            kimi: Self.expiredKimi(),
            deepseek: Self.healthyDeepSeek
        )
        #expect(state.overview.expiredProviders == [.kimi, .glm], "引擎侧按 Provider.allCases 序全记")
        #expect(Presentation.namedExpiredProviders(in: state) == [.kimi], "呈现侧按展示序且只点名凭据正常的")
        #expect(!Presentation.isAllPlansExpired(in: state))
    }

    @Test("三家全到期判定:凭据正常且全部到期才成立")
    func allExpiredRequiresEveryProvider() {
        #expect(Presentation.isAllPlansExpired(in: PreviewData.allPlansExpiredState()))
        #expect(!Presentation.isAllPlansExpired(in: PreviewData.glmExpiredState()))
    }

    @Test("彩色「—」取色跳过到期家:GLM 到期、唯一无窗持快照家 DeepSeek 健康 → 余额档给色")
    func coloredDashSkipsExpiredHolder() {
        // GLM 到期(5% 死档)、Kimi 未配置、DeepSeek 余额健康:无任何未到期窗口
        // → 总览条「—」,色只能来自持快照家——不能取 GLM 的死档。
        let state = Self.makeState(
            glm: Self.expiredGlm(),
            kimi: PreviewData.runtime(.kimi, snapshot: nil, credential: .missing),
            deepseek: Self.healthyDeepSeek
        )
        let presentation = GlobalPercentPresentation(state: state, scheme: .light, now: Self.now)
        #expect(presentation.text == "—")
        #expect(presentation.colorStatus == .normal, "DeepSeek 余额档给色,不是 GLM 的死档")
    }

    @Test("全部持快照家到期:「彩色 —」退灰(不给死数据档位留色)")
    func coloredDashTurnsGrayWhenAllHoldersExpired() {
        // GLM+Kimi 到期、DeepSeek 未配置:仅剩的持快照家都是到期家——这也是
        // #58 落地后用户真实会遇到的「全到期」形态(可自然达到,无需注入)。
        let state = Self.makeState(
            glm: Self.expiredGlm(),
            kimi: Self.expiredKimi(),
            deepseek: Self.unconfigured
        )
        let presentation = GlobalPercentPresentation(state: state, scheme: .light, now: Self.now)
        #expect(presentation.text == "—")
        #expect(presentation.colorStatus == nil)
    }
}
