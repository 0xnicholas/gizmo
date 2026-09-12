import Foundation
import Testing
@testable import UsageMonitorCore

/// EngineState 的派生展示口径:全新安装判定(总览条标题、凭据横幅两行形态共用)。
/// 口径:从未配置过任何凭据且无任何快照;钥匙串读取异常不算(状态未知时不误判,
/// 同首启引导口径)。
@Suite("全新安装判定(派生状态)")
struct EngineStateFreshInstallTests {
    private func runtime(
        _ provider: Provider,
        credential: CredentialState = .missing,
        snapshot: Snapshot? = nil
    ) -> ProviderRuntimeState {
        var state = ProviderRuntimeState(provider: provider)
        state.credential = credential
        state.snapshot = snapshot
        return state
    }

    @Test("全新安装:无凭据无快照")
    func freshInstall() {
        let state = EngineState(providers: [
            .glm: runtime(.glm),
            .kimi: runtime(.kimi),
            .deepseek: runtime(.deepseek),
        ])
        #expect(state.isFreshInstall)
    }

    @Test("已配置任一家凭据即非全新安装(即便还无快照)")
    func anyCredentialDisqualifies() {
        let state = EngineState(providers: [
            .glm: runtime(.glm, credential: .configured),
            .kimi: runtime(.kimi),
            .deepseek: runtime(.deepseek),
        ])
        #expect(!state.isFreshInstall)
    }

    @Test("钥匙串读取异常不算全新安装:状态未知时不误判")
    func readFailureDisqualifies() {
        var state = EngineState(providers: [
            .glm: runtime(.glm),
            .kimi: runtime(.kimi),
            .deepseek: runtime(.deepseek),
        ])
        state.credentialReadFailures = [.glm]
        #expect(!state.isFreshInstall)
    }

    @Test("已有快照即非全新安装(凭据后来被清掉也不回到全新安装口径)")
    func anySnapshotDisqualifies() {
        let snapshot = Fixture.snapshot(provider: .deepseek)
        // 与引擎同口径:overview 由快照现场推导(state 每次读取都重算,两者恒一致)。
        let state = EngineState(
            providers: [.deepseek: runtime(.deepseek, snapshot: snapshot)],
            overview: GlobalOverview.compute(snapshots: [.deepseek: snapshot], evaluator: StatusEvaluator())
        )
        #expect(!state.isFreshInstall)
    }
}
