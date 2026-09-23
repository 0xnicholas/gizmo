import Foundation
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// 菜单栏图标 a11y 一行说明的 Kimi 口径(#59,IC-2/P2-7 的 #45 改写):
/// 图标只有一个数字,VoiceOver 就该听到这一个数字的完整口径——哪窗多少、哪档;
/// 以及「—」的来历(未配置 / 凭据失效 / 读取失败 / 到期 / 加载失败 / 尚无数据)。
/// tooltip 共用同一文案,故这组断言同时是 tooltip 的文案契约。
@Suite("菜单栏图标 a11y 的 Kimi 口径(#59)")
struct MenuBarAccessibilityLabelTests {
    private static let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func label(_ state: EngineState, now: Date = Self.now) -> String {
        MenuBarAccessibilityPresentation(state: state, now: now).text
    }

    private func kimiRuntime(
        weekRemaining: Int = 66,
        age: TimeInterval = 5 * 60,
        credential: CredentialState = .configured,
        validity: PlanValidity? = nil,
        manualExpiry: ManualPlanExpiry? = nil,
        loadFailed: Bool = false,
        withSnapshot: Bool = true
    ) -> ProviderRuntimeState {
        PreviewData.runtime(
            .kimi,
            snapshot: withSnapshot
                ? PreviewData.kimi(
                    weekRemaining: weekRemaining,
                    validity: validity,
                    fetchedAt: Self.now.addingTimeInterval(-age)
                )
                : nil,
            credential: credential,
            loadFailed: loadFailed,
            manualExpiry: manualExpiry
        )
    }

    private func state(
        kimi: ProviderRuntimeState,
        glm: ProviderRuntimeState? = nil,
        credentialReadFailures: Set<Provider> = []
    ) -> EngineState {
        var providers: [Provider: ProviderRuntimeState] = [.kimi: kimi]
        if let glm { providers[.glm] = glm }
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

    /// 核心验收:GLM 5%(全局最紧)不进这行——一行说明只讲图标本体那个数字。
    @Test("主形态:只报 Kimi 的窗口与档位,别家再紧也不登场")
    func reportsKimiWindowAndTierOnly() {
        let state = self.state(kimi: kimiRuntime(), glm: healthyGLM(weeklyRemaining: 3_000))
        #expect(state.overview.tightest?.provider == .glm, "构造前提:全局最紧是 GLM")
        #expect(label(state) == "Kimi 周窗口剩余 66%,状态正常")
    }

    @Test("档位随 Kimi 自己:20% → 偏低,5% → 临界")
    func tierWordsFollowKimi() {
        #expect(label(state(kimi: kimiRuntime(weekRemaining: 20), glm: healthyGLM()))
            == "Kimi 周窗口剩余 20%,状态偏低")
        #expect(label(state(kimi: kimiRuntime(weekRemaining: 5), glm: healthyGLM()))
            == "Kimi 周窗口剩余 5%,状态临界")
    }

    /// 陈旧只有**视觉**表达(数字降透明度),读屏用户拿不到——同一事实得在这行里
    /// 说一遍,否则图标的降透明度对 VoiceOver 用户不存在。
    @Test("数据陈旧:一行说明补「数据较旧(最后成功 HH:mm)」")
    func staleFigureAddsAgeClause() {
        let state = self.state(kimi: kimiRuntime(age: 90 * 60), glm: healthyGLM())
        let lastSuccess = Presentation.time(Self.now.addingTimeInterval(-90 * 60))
        #expect(label(state) == "Kimi 周窗口剩余 66%,状态正常,数据较旧(最后成功 \(lastSuccess))")
    }

    /// 两个事实各占半句,时刻只报一次(陈旧 + 刷新失败同现时的完整形态,
    /// 就是自然轮询下的加载失败形态)。
    @Test("陈旧 + 加载失败:时刻不重复")
    func staleAndLoadFailedShareOneTimestamp() {
        let state = self.state(kimi: kimiRuntime(age: 90 * 60, loadFailed: true), glm: healthyGLM())
        let lastSuccess = Presentation.time(Self.now.addingTimeInterval(-90 * 60))
        #expect(label(state) == "Kimi 周窗口剩余 66%,状态正常,加载失败(最后成功 \(lastSuccess)),数据较旧")
    }

    /// 图标本体与这行说明的陈旧判定必须同源(看得见的不透明度 × 听得见的半句):
    /// 两处各算一次时,最典型的漂移就是一个说旧、一个不说。
    @Test("陈旧判定单一来源:图标 isStale 与陈旧半句同进同出")
    func stalenessAgreesBetweenIconAndLabel() {
        let cases: [(age: TimeInterval, stale: Bool)] = [
            (5 * 60, false),
            (MenuBarStaleness.threshold, false),
            (MenuBarStaleness.threshold + 60, true),
        ]
        for item in cases {
            let state = state(kimi: kimiRuntime(age: item.age))
            let icon = MenuBarPercentPresentation(state: state, scheme: .light, now: Self.now)
            #expect(icon.isStale == item.stale)
            #expect(label(state).contains("数据较旧") == item.stale)
        }
    }

    /// 窗口名缺失(解析层没给 label)时不留空档:回退「套餐窗口」,不念成「Kimi 剩余」。
    @Test("窗口名缺失:回退「Kimi 套餐窗口」")
    func missingWindowLabelFallsBack() {
        var runtime = kimiRuntime()
        if var snapshot = runtime.snapshot {
            for index in snapshot.windows.indices {
                snapshot.windows[index].label = ""
            }
            runtime.snapshot = snapshot
        }
        #expect(label(state(kimi: runtime)) == "Kimi 套餐窗口剩余 66%,状态正常")
    }

    /// IC-3:数字来自最后一次成功——旧数字要承认自己是旧的(与焦点卡/总览条同口径)。
    /// IC-3:数字来自最后一次成功——旧数字要承认自己是旧的(与焦点卡/总览条同口径);
    /// 自然轮询下加载失败必然同时陈旧(3 轮失败 ≈ 90 分钟 > 60 分钟阈值),
    /// 两个事实各占半句,「最后成功 HH:mm」只说一次。
    @Test("加载失败但持旧快照:报数字 + 最后成功时刻 + 数据较旧")
    func loadFailedWithSnapshotAdmitsLastSuccess() {
        let age: TimeInterval = 3 * 3_600
        let state = self.state(kimi: kimiRuntime(age: age, loadFailed: true), glm: healthyGLM())
        let lastSuccess = Presentation.time(Self.now.addingTimeInterval(-age))
        #expect(label(state) == "Kimi 周窗口剩余 66%,状态正常,加载失败(最后成功 \(lastSuccess)),数据较旧")
    }

    /// 与图标本体的降透明度正交(两口径的搭档断言):数据只旧 5 分钟就攒满失败的
    /// 那个形态下,图标不降透明度,「刷新失败」的事实只能由这行说明承担——
    /// 否则那个形态下没有任何地方承认失败。
    @Test("加载失败但数据新鲜:失败事实只在这行说明里")
    func loadFailureWithFreshDataIsTextOnly() {
        let state = self.state(kimi: kimiRuntime(age: 5 * 60, loadFailed: true), glm: healthyGLM())
        let lastSuccess = Presentation.time(Self.now.addingTimeInterval(-5 * 60))
        #expect(label(state) == "Kimi 周窗口剩余 66%,状态正常,加载失败(最后成功 \(lastSuccess))")
    }

    @Test("加载失败且从无成功:连旧数字都没有,「—」的来历讲成加载失败")
    func loadFailedWithoutSnapshot() {
        let state = self.state(kimi: kimiRuntime(loadFailed: true, withSnapshot: false))
        #expect(label(state) == "用量监视器,Kimi 加载失败,尚无数据")
    }

    @Test("未配置(含全新安装):报未配置,不留「是不是没联网」的歧义")
    func missingCredentialExplainsDash() {
        let state = self.state(kimi: kimiRuntime(credential: .missing, withSnapshot: false))
        #expect(label(state) == "用量监视器,Kimi 尚未配置凭据")
        #expect(label(PreviewData.freshState()) == "用量监视器,Kimi 尚未配置凭据")
    }

    @Test("凭据失效:报失效与出路(即使持旧快照)")
    func invalidCredentialExplainsDash() {
        let state = self.state(kimi: kimiRuntime(credential: .invalid))
        #expect(label(state) == "用量监视器,Kimi 凭据失效,请在设置中重新配置")
    }

    @Test("钥匙串读取失败:报状态未知,不误报「未配置」")
    func credentialReadFailureExplainsDash() {
        let state = self.state(
            kimi: kimiRuntime(credential: .missing, withSnapshot: false),
            credentialReadFailures: [.kimi]
        )
        #expect(label(state) == "用量监视器,Kimi 凭据状态未知(钥匙串读取失败)")
    }

    @Test("套餐自动到期:报到期(不报「没数据」)")
    func expiredPlanExplainsDash() {
        let state = self.state(kimi: kimiRuntime(validity: expiredValidity()), glm: healthyGLM())
        #expect(label(state) == "用量监视器,Kimi 套餐已到期")
    }

    @Test("手动标记到期:报到期并标注是手动标记(#58)")
    func manuallyExpiredPlanExplainsDash() {
        let manual = ManualPlanExpiry(markedAt: Self.now.addingTimeInterval(-86_400))
        let state = self.state(kimi: kimiRuntime(manualExpiry: manual), glm: healthyGLM())
        #expect(label(state) == "用量监视器,Kimi 套餐已到期(手动标记)")
    }

    /// 凭据问题优先于到期(全库同序):失效家不做到期断言,否则会把用户引到「去续订」。
    @Test("凭据失效 + 已到期:报凭据失效,不做到期断言")
    func credentialProblemBeatsExpiry() {
        let state = self.state(kimi: kimiRuntime(credential: .invalid, validity: expiredValidity()))
        #expect(label(state) == "用量监视器,Kimi 凭据失效,请在设置中重新配置")
    }

    /// 只持非套餐窗(现实里不会出现,防解析层将来少给一个窗口时讲歪)。
    @Test("快照只有频限窗:报「暂无套餐窗口数据」")
    func snapshotWithoutPlanWindowExplainsDash() {
        var runtime = kimiRuntime()
        runtime.snapshot = PreviewData.kimi(rateLimitOnly: true, fetchedAt: Self.now.addingTimeInterval(-5 * 60))
        let state = self.state(kimi: runtime)
        #expect(label(state) == "用量监视器,Kimi 暂无套餐窗口数据")
    }
}
