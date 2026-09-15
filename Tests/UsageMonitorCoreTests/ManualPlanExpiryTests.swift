import Foundation
import Testing
@testable import UsageMonitorCore

/// 手动到期声明的纯编辑逻辑(#58):标记 / 取消 / 时间戳 / 读取。
/// 存储 I/O 在 App 侧(UserDefaults,与「登录自启已表态」同类);这里只做声明值的
/// 语义与合法性判定——不新增协议、不新增模块。
@Suite("手动到期声明:编辑逻辑(#58)")
struct ManualPlanExpiryEditingTests {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    @Test("标记:时间戳取调用方给的当刻(时钟单源,测试可拨)")
    func markUsesInjectedNow() {
        #expect(ManualPlanExpiryEditing.mark(at: now) == ManualPlanExpiry(markedAt: now))
        #expect(ManualPlanExpiryEditing.mark(at: now.addingTimeInterval(60)).markedAt == now.addingTimeInterval(60))
    }

    @Test("取消:声明清除(结果是无声明,调用方据此移除存储)")
    func clearRemovesDeclaration() {
        #expect(ManualPlanExpiryEditing.clear() == nil)
    }

    @Test("读取:存储原文里只有 Date 才算声明;缺失/类型不符都不是声明")
    func declarationFromStoredValue() {
        #expect(ManualPlanExpiryEditing.declaration(fromStored: now) == ManualPlanExpiry(markedAt: now))
        #expect(ManualPlanExpiryEditing.declaration(fromStored: nil) == nil)
        #expect(ManualPlanExpiryEditing.declaration(fromStored: "2026-09-15") == nil, "类型不符不误报")
        #expect(ManualPlanExpiryEditing.declaration(fromStored: 42) == nil)
    }
}

/// 手动入口的适用面(#58):只有 App 无从得知有效期、且「套餐到期」语义成立的家。
@Suite("手动入口适用面(#58)")
struct ManualPlanExpirySupportTests {
    @Test("只给 Kimi:GLM 有自动来源(自动判定优先),DeepSeek 余额型恒 unknown")
    func onlyKimiSupportsManualMarking() {
        #expect(Provider.kimi.supportsManualPlanExpiry)
        #expect(!Provider.glm.supportsManualPlanExpiry)
        #expect(!Provider.deepseek.supportsManualPlanExpiry)
    }
}

/// 引擎侧的手动声明(#58):与「凭据已清除」同型的注入口、运行态、全局口径与通知口径。
/// 手动是用户表态:不发任何通知(自己按的按钮),但「不能当结论用」的退出口径全部生效。
@Suite("引擎:手动标记到期(#58)")
struct ManualPlanExpiryEngineTests {
    private let epoch = Fixture.epoch

    @Test("注入声明:运行态带上它,总览把该家剔出结论(图标/最紧/最差)")
    func manualMarkExcludesFromGlobalConclusions() async {
        // Kimi 周窗 5%(临界、全局最紧)——标记后应退出全部全局结论
        let harness = EngineHarness(payloads: [.glm: Payloads.glm(), .kimi: Payloads.kimi(weekRemaining: 5)])
        _ = await harness.engine.refreshAll()
        var state = await harness.engine.state
        #expect(state.overview.tightest?.provider == .kimi)
        #expect(state.overview.worstStatus == .critical)
        #expect(state.overview.expiredProviders.isEmpty)

        let markedAt = epoch.addingTimeInterval(-3_600)
        await harness.engine.setManualPlanExpiry(ManualPlanExpiry(markedAt: markedAt), for: .kimi)
        state = await harness.engine.state
        #expect(state.provider(.kimi).manualPlanExpiry == ManualPlanExpiry(markedAt: markedAt))
        #expect(state.overview.expiredProviders == [.kimi])
        #expect(state.overview.tightest?.provider == .glm, "最紧轮到未到期家")
        #expect(state.overview.worstStatus == .low, "死档不拉低全局最差:剩下 GLM 自身的偏低档")
        #expect(state.provider(.kimi).status == .critical, "status 推导不变——只有口径剔除")
    }

    @Test("取消声明:恢复原样(重新参与全局结论)")
    func clearingRestoresParticipation() async {
        let harness = EngineHarness(payloads: [.glm: Payloads.glm(), .kimi: Payloads.kimi(weekRemaining: 5)])
        _ = await harness.engine.refreshAll()
        await harness.engine.setManualPlanExpiry(ManualPlanExpiry(markedAt: epoch), for: .kimi)
        #expect(await harness.engine.state.overview.expiredProviders == [.kimi])

        await harness.engine.setManualPlanExpiry(ManualPlanExpiryEditing.clear(), for: .kimi)
        let state = await harness.engine.state
        #expect(state.provider(.kimi).manualPlanExpiry == nil)
        #expect(state.overview.expiredProviders.isEmpty)
        #expect(state.overview.tightest?.provider == .kimi)
    }

    @Test("手动标记的家不发临界通知(与到期家同口径);未标记时照发")
    func manualMarkedHomeSuppressesCriticalNotifications() async {
        let marked = EngineHarness(payloads: [.kimi: Payloads.kimi(weekRemaining: 5)])
        await marked.engine.setManualPlanExpiry(ManualPlanExpiry(markedAt: epoch), for: .kimi)
        let events = await marked.engine.refreshAll()
        #expect(!events.contains { $0.notificationKind == "usage" }, "不能用的额度不报临界")
        #expect(await marked.engine.state.provider(.kimi).status == .critical)

        let unmarked = EngineHarness(payloads: [.kimi: Payloads.kimi(weekRemaining: 5)])
        let loud = await unmarked.engine.refreshAll()
        #expect(loud.contains { $0.notificationKind == "usage" })
    }

    @Test("标记/取消都静默:不发 #57 的三类到期提醒;手动到期家也不报「已到期」")
    func manualMarkingIsSilent() async {
        let harness = EngineHarness(payloads: [.kimi: Payloads.kimi()])
        _ = await harness.engine.refreshAll()
        await harness.engine.setManualPlanExpiry(ManualPlanExpiry(markedAt: epoch), for: .kimi)

        harness.clock.advance(2 * 86_400)
        #expect(await harness.engine.refreshAll().planNotices.isEmpty, "手动到期不冒充 provider 事实发提醒")

        await harness.engine.setManualPlanExpiry(nil, for: .kimi)
        #expect(await harness.engine.refreshAll().planNotices.isEmpty, "取消也不发「已恢复」")
    }

    @Test("provider 侧能判时手动声明不生效:GLM 注入声明也照旧判(自动来源优先)")
    func manualDeclarationDoesNotOverrideProviderSource() async {
        let harness = EngineHarness(payloads: [.glm: Payloads.glm()], manualExpiry: [.glm: ManualPlanExpiry(markedAt: epoch)])
        _ = await harness.engine.refreshAll()
        let state = await harness.engine.state
        #expect(state.provider(.glm).manualPlanExpiry == ManualPlanExpiry(markedAt: epoch), "声明原样持有(存储不丢)")
        #expect(state.overview.expiredProviders.isEmpty, "但不生效:provider 侧未到期")
    }

    @Test("重启后仍在:声明随引擎构造注入(存储由 App 侧读盘),首个 state 即生效")
    func declarationRestoredAtLaunch() async {
        let cached = Fixture.snapshot(
            provider: .kimi,
            windows: [Fixture.planWindow(limit: 100, remaining: 66, label: "周窗口", unit: "请求")]
        )
        let harness = EngineHarness(
            cached: [.kimi: cached],
            manualExpiry: [.kimi: ManualPlanExpiry(markedAt: epoch.addingTimeInterval(-86_400))]
        )
        _ = await harness.engine.start()
        let state = await harness.engine.state
        #expect(state.provider(.kimi).manualPlanExpiry == ManualPlanExpiry(markedAt: epoch.addingTimeInterval(-86_400)))
        #expect(state.overview.expiredProviders == [.kimi])
    }
}

/// planState 的手动案(#58):用户声明与 provider 侧判定正交——
/// provider 侧能判时手动永不覆盖;无声明时与今天完全一致。
@Suite("planState 手动标记(#58)")
struct PlanStateManualTests {
    private let now = Fixture.epoch
    private let markedAt = Fixture.epoch.addingTimeInterval(-86_400)

    /// 无有效期来源的快照(现实里 Kimi 的形状)。
    private func sourceLessSnapshot(_ provider: Provider = .kimi) -> Snapshot {
        Fixture.snapshot(
            provider: provider,
            windows: [Fixture.planWindow(limit: 100, remaining: 66, label: "周窗口", unit: "请求")]
        )
    }

    @Test("无 provider 有效期的家(Kimi)+ 手动声明 → manuallyExpired,带标记时刻;isExpired 成立")
    func manualDeclarationProducesManualState() {
        let state = PlanState.evaluate(
            provider: .kimi,
            snapshot: sourceLessSnapshot(),
            manualExpiry: ManualPlanExpiry(markedAt: markedAt),
            now: now
        )
        #expect(state == .manuallyExpired(markedAt: markedAt))
        #expect(state.isExpired)
        #expect(!PlanState.evaluate(provider: .kimi, snapshot: sourceLessSnapshot(), manualExpiry: nil, now: now).isExpired, "无声明不灰")
    }

    @Test("provider 侧能判时手动声明永不覆盖:有效期内 + 声明 → active;到期 + 声明 → expired(provider 侧)")
    func providerSourceWins() {
        let validity = Fixture.validity(validUntil: now.addingTimeInterval(10 * 86_400))
        let active = PlanState.evaluate(
            provider: .glm,
            snapshot: Fixture.snapshot(provider: .glm, planValidity: validity),
            manualExpiry: ManualPlanExpiry(markedAt: markedAt),
            now: now
        )
        #expect(active == .active(validUntil: validity.validUntil, autoRenew: false, observedAt: Fixture.epoch))

        let expired = PlanState.evaluate(
            provider: .glm,
            snapshot: Fixture.snapshot(provider: .glm, planValidity: Fixture.validity(validUntil: now.addingTimeInterval(-3_600))),
            manualExpiry: ManualPlanExpiry(markedAt: markedAt),
            now: now
        )
        #expect(expired == .expired(validUntil: now.addingTimeInterval(-3_600), observedAt: Fixture.epoch))
    }

    @Test("有自动来源的家不提供手动覆盖:provider 侧当前无结论(GLM 无有效期)也不接受声明")
    func providerBackedHomeRejectsManualDeclaration() {
        let state = PlanState.evaluate(
            provider: .glm,
            snapshot: sourceLessSnapshot(.glm),
            manualExpiry: ManualPlanExpiry(markedAt: markedAt),
            now: now
        )
        #expect(state == .unknown)
    }

    @Test("DeepSeek 恒 unknown:声明也不改变(余额型不在这套机制里)")
    func deepseekStaysUnknown() {
        let state = PlanState.evaluate(
            provider: .deepseek,
            snapshot: sourceLessSnapshot(.deepseek),
            manualExpiry: ManualPlanExpiry(markedAt: markedAt),
            now: now
        )
        #expect(state == .unknown)
    }

    @Test("运行时态求值(引擎与 UI 的共享入口)与三元组求值同源")
    func runtimeConvenienceMatchesPrimitive() {
        var runtime = ProviderRuntimeState(provider: .kimi)
        runtime.credential = .configured
        runtime.snapshot = sourceLessSnapshot()
        #expect(PlanState.evaluate(runtime: runtime, now: now) == .unknown)

        runtime.manualPlanExpiry = ManualPlanExpiry(markedAt: markedAt)
        #expect(PlanState.evaluate(runtime: runtime, now: now) == .manuallyExpired(markedAt: markedAt))
        #expect(
            PlanState.evaluate(runtime: runtime, now: now)
                == PlanState.evaluate(
                    provider: .kimi,
                    snapshot: runtime.snapshot,
                    manualExpiry: runtime.manualPlanExpiry,
                    now: now
                )
        )
    }
}
