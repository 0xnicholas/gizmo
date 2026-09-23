import Foundation
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// 菜单栏图标口径(#59):图标恒为 **Kimi 一家**——数字取 Kimi 最紧 plan-window
/// 剩余%,颜色随 Kimi 自身 status。他者更紧(含 DeepSeek 余额档)不改图标:
/// 「谁最紧显示谁」的旧口径与 DeepSeek-only 彩色「—」形态退出菜单栏,
/// 口径乙只活在 popover 总览条(`GlobalPercentColorStatusTests` 仍在守那边)。
/// 没有数字的来历(凭据问题 / 到期)一律灰「—」,文案归 `MenuBarAccessibilityLabelTests`。
@Suite("菜单栏图标 Kimi 口径(#59)")
struct MenuBarKimiPresentationTests {
    private static let now = Date(timeIntervalSince1970: 1_789_000_000)
    private static let staleThreshold: TimeInterval = 2 * Thresholds().refreshInterval

    private func presentation(_ state: EngineState) -> MenuBarPercentPresentation {
        MenuBarPercentPresentation(state: state, scheme: .light, now: Self.now)
    }

    /// Kimi 运行态:快照 fetchedAt 相对固定的 now 构造,数据新旧才有可控轴
    /// (陈旧标记按 Kimi 自己的 lastSuccessAt)。
    private func kimiRuntime(
        weekRemaining: Int = 66,
        rateLimitRemaining: Int = 90,
        age: TimeInterval = 5 * 60,
        credential: CredentialState = .configured,
        validity: PlanValidity? = nil,
        manualExpiry: ManualPlanExpiry? = nil,
        withSnapshot: Bool = true
    ) -> ProviderRuntimeState {
        PreviewData.runtime(
            .kimi,
            snapshot: withSnapshot
                ? PreviewData.kimi(
                    weekRemaining: weekRemaining,
                    rateLimitRemaining: rateLimitRemaining,
                    validity: validity,
                    fetchedAt: Self.now.addingTimeInterval(-age)
                )
                : nil,
            credential: credential,
            manualExpiry: manualExpiry
        )
    }

    /// 全量状态:他者一律健康,便于把「别家更紧 / 别家刷新」当噪音注入。
    private func state(
        kimi: ProviderRuntimeState,
        glm: ProviderRuntimeState? = nil,
        deepseek: ProviderRuntimeState? = nil,
        credentialReadFailures: Set<Provider> = []
    ) -> EngineState {
        var providers: [Provider: ProviderRuntimeState] = [.kimi: kimi]
        if let glm { providers[.glm] = glm }
        if let deepseek { providers[.deepseek] = deepseek }
        return EngineState(
            providers: providers,
            credentialReadFailures: credentialReadFailures,
            overview: GlobalOverview.compute(
                snapshots: providers.compactMapValues(\.snapshot),
                evaluator: StatusEvaluator(),
                now: Self.now
            )
        )
    }

    private func healthyGLM(weeklyRemaining: Int = 39_000) -> ProviderRuntimeState {
        PreviewData.runtime(.glm, snapshot: PreviewData.glm(weeklyRemaining: weeklyRemaining))
    }

    /// 已到期的有效期:相对固定 now 构造(`PreviewData.validity` 以真实时钟为基准,
    /// 与固定 now 的测试不同轴)。
    private func expiredValidity() -> PlanValidity {
        PlanValidity(
            validFrom: Self.now.addingTimeInterval(-32 * 86_400),
            validUntil: Self.now.addingTimeInterval(-2 * 86_400),
            status: "EXPIRED",
            observedAt: Self.now.addingTimeInterval(-2 * 86_400)
        )
    }

    /// 核心验收:GLM 5%(全局最紧、红)+ DeepSeek 临界,图标仍显 Kimi 的绿 66%。
    @Test("GLM 更紧也不改图标:显 Kimi 66% 绿,不显 GLM 5% 红")
    func tighterOtherProviderDoesNotHijackIcon() {
        let state = self.state(
            kimi: kimiRuntime(weekRemaining: 66),
            glm: healthyGLM(weeklyRemaining: 3_000),
            deepseek: PreviewData.runtime(.deepseek, snapshot: PreviewData.deepseek(total: "8.20"))
        )
        #expect(state.overview.tightest?.provider == .glm, "构造前提:全局最紧确实是 GLM")
        let icon = presentation(state)
        #expect(icon.text == "66%")
        #expect(icon.colorStatus == .normal)
    }

    @Test("颜色随 Kimi 自身档位:20% → 黄")
    func kimiLowTierColorsYellow() {
        let icon = presentation(state(kimi: kimiRuntime(weekRemaining: 20), glm: healthyGLM()))
        #expect(icon.text == "20%")
        #expect(icon.colorStatus == .low)
    }

    @Test("颜色随 Kimi 自身档位:5% → 红(GLM 健康不拖色)")
    func kimiCriticalTierColorsRed() {
        let icon = presentation(state(kimi: kimiRuntime(weekRemaining: 5), glm: healthyGLM()))
        #expect(icon.text == "5%")
        #expect(icon.colorStatus == .critical)
    }

    /// 频限窗不参与 status 判定,也不该改图标数字:滚动窗见底时图标仍是周窗口的 66%。
    @Test("Kimi 频限滚动窗见底不改数字(只有套餐窗参与)")
    func rateLimitWindowDoesNotDriveFigure() {
        let icon = presentation(state(kimi: kimiRuntime(weekRemaining: 66, rateLimitRemaining: 1)))
        #expect(icon.text == "66%")
        #expect(icon.colorStatus == .normal)
    }

    /// 只持频限窗的快照(套餐窗缺席):没有套餐窗数字就灰「—」——
    /// 菜单栏不再有口径乙的「彩色 —」(那口形态留在总览条)。
    @Test("快照只有频限窗:灰「—」,不给彩色空档")
    func snapshotWithoutPlanWindowStaysGray() {
        var runtime = kimiRuntime()
        runtime.snapshot = PreviewData.kimi(rateLimitOnly: true, fetchedAt: Self.now.addingTimeInterval(-5 * 60))
        let icon = presentation(state(kimi: runtime))
        #expect(icon.text == "—")
        #expect(icon.colorStatus == nil)
    }

    @Test("Kimi 未配置:灰「—」")
    func missingCredentialIsGray() {
        let icon = presentation(state(kimi: kimiRuntime(credential: .missing, withSnapshot: false)))
        #expect(icon.text == "—")
        #expect(icon.colorStatus == nil)
    }

    /// 凭据失效时旧数字不再上场:冻结的数字会假装新鲜(凭据问题归 a11y 与 popover 横幅)。
    @Test("Kimi 凭据失效:旧快照 66% 也不给数字,灰「—」")
    func invalidCredentialHidesFrozenFigure() {
        let icon = presentation(state(kimi: kimiRuntime(weekRemaining: 66, credential: .invalid)))
        #expect(icon.text == "—")
        #expect(icon.colorStatus == nil)
    }

    @Test("Kimi 钥匙串读取失败:灰「—」(状态未知不等于有数据)")
    func credentialReadFailureIsGray() {
        let kimi = kimiRuntime(credential: .missing, withSnapshot: false)
        let icon = presentation(state(kimi: kimi, credentialReadFailures: [.kimi]))
        #expect(icon.text == "—")
        #expect(icon.colorStatus == nil)
    }

    @Test("Kimi 套餐自动到期:灰「—」(死档不留百分比)")
    func expiredPlanIsGray() {
        let icon = presentation(state(kimi: kimiRuntime(weekRemaining: 66, validity: expiredValidity())))
        #expect(icon.text == "—")
        #expect(icon.colorStatus == nil)
    }

    @Test("Kimi 手动标记到期:灰「—」(#58 的手动态同属到期)")
    func manuallyExpiredPlanIsGray() {
        let manual = ManualPlanExpiry(markedAt: Self.now.addingTimeInterval(-86_400))
        let icon = presentation(state(kimi: kimiRuntime(weekRemaining: 66, manualExpiry: manual)))
        #expect(icon.text == "—")
        #expect(icon.colorStatus == nil)
    }

    // MARK: - 陈旧标记(IC-3):按 Kimi 自己的 lastSuccessAt

    @Test("超 60 分钟(2× 轮询间隔)带陈旧标记,数字本身不变")
    func staleBeyondThreshold() {
        let icon = presentation(state(kimi: kimiRuntime(age: Self.staleThreshold + 60)))
        #expect(icon.text == "66%")
        #expect(icon.isStale)
    }

    @Test("未超不带;整 60 分钟不算超过")
    func freshWithinThreshold() {
        #expect(!presentation(state(kimi: kimiRuntime(age: Self.staleThreshold))).isStale)
        #expect(!presentation(state(kimi: kimiRuntime(age: Self.staleThreshold - 60))).isStale)
        #expect(!presentation(state(kimi: kimiRuntime(age: 5 * 60))).isStale)
    }

    /// 别家刚刷新过不能给 Kimi 的数字背书(旧口径用全局 lastUpdatedAt 会在此骗人)。
    @Test("不被别家成功刷新冲掉:Kimi 90 分钟前、GLM 1 分钟前仍陈旧")
    func otherProvidersFreshnessDoesNotClearStaleness() {
        let icon = presentation(
            state(
                kimi: kimiRuntime(age: 90 * 60),
                glm: PreviewData.runtime(.glm, snapshot: PreviewData.glm(fetchedAt: Self.now.addingTimeInterval(-60)))
            )
        )
        #expect(icon.isStale)
    }

    @Test("无数字(灰「—」)不判陈旧")
    func noFigureIsNeverStale() {
        #expect(!presentation(state(kimi: kimiRuntime(credential: .missing, withSnapshot: false))).isStale)
        #expect(!presentation(state(kimi: kimiRuntime(validity: expiredValidity()))).isStale)
    }
}
