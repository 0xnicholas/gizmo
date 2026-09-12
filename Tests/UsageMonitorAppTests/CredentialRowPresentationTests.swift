import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// 凭据状态行的收拢口径(骨架C,P1-5,#38):全部已配置且无读取失败时收成一行
/// 「三家凭据正常 · 管理」;有任何问题(失效/未配置/读取失败)时只展开问题家。
/// 横幅管汇总、行管逐家入口的分工不变——此处只决定行自身收不收、展开谁。
@Suite("凭据状态行全绿收拢(骨架C)")
struct CredentialRowPresentationTests {
    private func state(
        glm: CredentialState = .configured,
        kimi: CredentialState = .configured,
        deepseek: CredentialState = .configured,
        readFailures: Set<Provider> = [],
        glmLoadFailed: Bool = false
    ) -> EngineState {
        func runtime(_ provider: Provider, credential: CredentialState, loadFailed: Bool = false) -> ProviderRuntimeState {
            var runtime = ProviderRuntimeState(provider: provider)
            runtime.credential = credential
            runtime.loadFailed = loadFailed
            return runtime
        }
        return EngineState(
            providers: [
                .glm: runtime(.glm, credential: glm, loadFailed: glmLoadFailed),
                .kimi: runtime(.kimi, credential: kimi),
                .deepseek: runtime(.deepseek, credential: deepseek),
            ],
            credentialReadFailures: readFailures
        )
    }

    @Test("三家全部已配置且无读取失败:收拢一行")
    func allConfiguredCollapses() {
        let presentation = CredentialRowPresentation(state: state())
        #expect(presentation.isCollapsed)
        #expect(presentation.problemProviders.isEmpty)
    }

    @Test("任一家凭据失效:展开,且只含问题家")
    func invalidExpandsOnlyProblemProvider() {
        let presentation = CredentialRowPresentation(state: state(kimi: .invalid))
        #expect(!presentation.isCollapsed)
        #expect(presentation.problemProviders == [.kimi])
    }

    @Test("任一家未配置:展开,且只含问题家")
    func missingExpandsOnlyProblemProvider() {
        let presentation = CredentialRowPresentation(state: state(deepseek: .missing))
        #expect(!presentation.isCollapsed)
        #expect(presentation.problemProviders == [.deepseek])
    }

    @Test("钥匙串读取失败:状态未知也算问题家(凭据字段可能仍是 missing)")
    func readFailureIsProblem() {
        let presentation = CredentialRowPresentation(state: state(readFailures: [.glm]))
        #expect(!presentation.isCollapsed)
        #expect(presentation.problemProviders == [.glm])
    }

    @Test("读取失败但凭据字段为 configured:仍展开(读不到 ≠ 正常;引擎现路径不产出该组合,口径上读取失败优先)")
    func readFailureWithConfiguredFieldStillExpands() {
        // state() 默认三家 .configured,叠加 readFailures 即得「configured + 读取失败」组合。
        let presentation = CredentialRowPresentation(state: state(readFailures: [.kimi]))
        #expect(!presentation.isCollapsed)
        #expect(presentation.problemProviders == [.kimi])
    }

    @Test("加载失败但凭据已配置:不算凭据问题,照常收拢(分工:失败态归焦点卡/横幅不管它)")
    func loadFailedConfiguredStillCollapses() {
        let presentation = CredentialRowPresentation(state: state(glmLoadFailed: true))
        #expect(presentation.isCollapsed)
        #expect(presentation.problemProviders.isEmpty)
    }

    @Test("多家问题时按展示序展开")
    func multipleProblemsKeepDisplayOrder() {
        let presentation = CredentialRowPresentation(
            state: state(kimi: .invalid, deepseek: .missing, readFailures: [.glm])
        )
        #expect(!presentation.isCollapsed)
        #expect(presentation.problemProviders == [.glm, .kimi, .deepseek])
    }

    @Test("快照有无不影响收拢:凭据口径只看凭据")
    func snapshotsIrrelevant() {
        var withSnapshot = state()
        var glm = withSnapshot.providers[.glm]!
        glm.snapshot = PreviewData.glm()
        withSnapshot.providers[.glm] = glm
        #expect(CredentialRowPresentation(state: withSnapshot).isCollapsed)
    }
}
