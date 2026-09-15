#if DEBUG
import SwiftUI
import UsageMonitorCore

/// 手动验收用的样例数据(占位值,不发网络请求)。原型形态见 `prototype/*` 分支。
enum PreviewData {
    /// 快照时间相对现在构造:陈旧标记(2× 轮询间隔)的注入才有可控的新旧轴(IC-3)。
    /// 健康形态默认 5 分钟前(新鲜);渲染产物里的具体时间随渲染时刻漂移,验收只断言模式。
    static let freshAge: TimeInterval = 5 * 60

    private static func freshFetchedAt() -> Date {
        Date().addingTimeInterval(-freshAge)
    }

    static func runtime(
        _ provider: Provider,
        snapshot: Snapshot?,
        credential: CredentialState = .configured,
        status: ProviderStatus? = nil,
        loadFailed: Bool = false,
        consecutiveFailures: Int = 0
    ) -> ProviderRuntimeState {
        var runtime = ProviderRuntimeState(provider: provider)
        runtime.snapshot = snapshot
        runtime.credential = credential
        // 样例状态也走真实推导,避免预览与引擎行为不一致
        runtime.status = status ?? snapshot.map { StatusEvaluator().status(for: $0) } ?? .normal
        runtime.loadFailed = loadFailed
        runtime.consecutiveFailures = consecutiveFailures
        runtime.lastSuccessAt = snapshot?.meta.fetchedAt
        return runtime
    }

    static func glm(
        rollingUsage: RollingUsage? = .value(amount: 7_500_000, unit: "tokens"),
        weeklyRemaining: Int = 15_929,
        validity: PlanValidity? = PreviewData.validity(),
        fetchedAt: Date = PreviewData.freshFetchedAt()
    ) -> Snapshot {
        Snapshot(
            meta: SnapshotMeta(provider: .glm, plan: Plan(level: "pro"), fetchedAt: fetchedAt, concurrencyLimit: nil),
            windows: [
                QuotaWindow(kind: .planWindow, label: "5 小时窗", unit: "积分", limit: 12_000, used: 641, remaining: 11_358, resetAt: fetchedAt.addingTimeInterval(3_600)),
                QuotaWindow(kind: .planWindow, label: "7 天窗", unit: "积分", limit: 60_000, used: 60_000 - weeklyRemaining, remaining: weeklyRemaining, resetAt: fetchedAt.addingTimeInterval(3 * 86_400)),
            ],
            balances: [],
            rollingUsage: rollingUsage,
            planValidity: validity,
            raw: "{}"
        )
    }

    /// 套餐有效期样例(#53):相对现在构造——区间盖住当下(常态「有效期至」行),
    /// 具体日期随渲染时刻漂移,验收只断言模式(若需固定日期形态可传 offsets)。
    /// observedAt(#54):到期场景里单独控制有效期的观测时刻(陈旧归属轴)。
    static func validity(
        untilDays: Double = 30,
        fromDays: Double = -30,
        observedAt: Date? = nil
    ) -> PlanValidity {
        let now = Date()
        return PlanValidity(
            validFrom: now.addingTimeInterval(fromDays * 86_400),
            validUntil: now.addingTimeInterval(untilDays * 86_400),
            status: "VALID",
            autoRenew: false,
            productName: "GLM Coding Pro",
            observedAt: observedAt
        )
    }

    static func kimi(weekRemaining: Int = 66, fetchedAt: Date = PreviewData.freshFetchedAt()) -> Snapshot {
        Snapshot(
            meta: SnapshotMeta(provider: .kimi, plan: Plan(level: "Allegretto", domain: "DOMAIN_NEXUS"), fetchedAt: fetchedAt, concurrencyLimit: 20),
            windows: [
                QuotaWindow(kind: .planWindow, label: "周窗口", unit: "请求", limit: 100, used: 100 - weekRemaining, remaining: weekRemaining, resetAt: fetchedAt.addingTimeInterval(6 * 86_400)),
                QuotaWindow(kind: .rateLimit, label: "频限 · 滚动窗(300 分钟)", unit: "请求", limit: 100, used: 10, remaining: 90, resetAt: fetchedAt.addingTimeInterval(1_800)),
            ],
            balances: [Balance(type: .wallet, amount: Decimal(string: "3.5")!, currency: "CNY")],
            rollingUsage: nil,
            raw: "{}"
        )
    }

    static func deepseek(total: String = "8.20", fetchedAt: Date = PreviewData.freshFetchedAt()) -> Snapshot {
        let amount = Decimal(string: total, locale: Locale(identifier: "en_US_POSIX"))!
        return Snapshot(
            meta: SnapshotMeta(provider: .deepseek, plan: nil, fetchedAt: fetchedAt, concurrencyLimit: nil, accountAvailable: amount >= 10),
            windows: [],
            balances: [
                Balance(type: .topUp, amount: amount - 3, currency: "CNY"),
                Balance(type: .granted, amount: 3, currency: "CNY"),
            ],
            rollingUsage: nil,
            raw: "{}"
        )
    }

    /// 全新安装:三家都未配置。
    static func freshState() -> EngineState {
        var providers: [Provider: ProviderRuntimeState] = [:]
        for provider in Provider.displayOrder {
            providers[provider] = runtime(provider, snapshot: nil, credential: .missing)
        }
        return EngineState(providers: providers)
    }

    /// 错误形态:Kimi 凭据失效、GLM 加载失败(仍持有 3 小时前的旧数据)、DeepSeek 未配置。
    static func errorState() -> EngineState {
        var providers: [Provider: ProviderRuntimeState] = [:]
        providers[.glm] = runtime(
            .glm,
            snapshot: glm(rollingUsage: .failed, weeklyRemaining: 2_000, fetchedAt: Date().addingTimeInterval(-3 * 3_600)),
            loadFailed: true,
            consecutiveFailures: 3
        )
        providers[.kimi] = runtime(.kimi, snapshot: kimi(weekRemaining: 66), credential: .invalid)
        providers[.deepseek] = runtime(.deepseek, snapshot: nil, credential: .missing)
        return EngineState(
            providers: providers,
            lastRefreshStartedAt: Date().addingTimeInterval(-3 * 3_600),
            overview: GlobalOverview.compute(
                snapshots: providers.compactMapValues(\.snapshot),
                evaluator: StatusEvaluator()
            )
        )
    }

    static func overviewState() -> EngineState {
        var providers: [Provider: ProviderRuntimeState] = [:]
        let glmSnapshot = glm()
        providers[.glm] = runtime(.glm, snapshot: glmSnapshot)
        providers[.kimi] = runtime(.kimi, snapshot: kimi(weekRemaining: 66))
        providers[.deepseek] = runtime(.deepseek, snapshot: deepseek())
        return EngineState(
            providers: providers,
            lastRefreshStartedAt: Date().addingTimeInterval(-freshAge),
            lastRefreshFinishedAt: Date().addingTimeInterval(-freshAge),
            overview: GlobalOverview.compute(
                snapshots: providers.compactMapValues(\.snapshot),
                evaluator: StatusEvaluator()
            )
        )
    }

    /// 场景形态共用构造:GLM 7 天窗剩余按入参取档,他者健康;glmAge 控制 GLM 数据新旧;
    /// deepseekTotal 控制 DeepSeek 余额档(口径乙验收用 8.20 复现临界)。
    private static func scenarioState(glmWeeklyRemaining: Int, glmAge: TimeInterval = freshAge, deepseekTotal: String = "62.47") -> EngineState {
        var providers: [Provider: ProviderRuntimeState] = [:]
        providers[.glm] = runtime(.glm, snapshot: glm(weeklyRemaining: glmWeeklyRemaining, fetchedAt: Date().addingTimeInterval(-glmAge)))
        providers[.kimi] = runtime(.kimi, snapshot: kimi(weekRemaining: 66))
        providers[.deepseek] = runtime(.deepseek, snapshot: deepseek(total: deepseekTotal))
        return EngineState(
            providers: providers,
            lastRefreshStartedAt: Date().addingTimeInterval(-glmAge),
            lastRefreshFinishedAt: Date().addingTimeInterval(-glmAge),
            overview: GlobalOverview.compute(
                snapshots: providers.compactMapValues(\.snapshot),
                evaluator: StatusEvaluator()
            )
        )
    }

    /// 正常形态:三家全绿(GLM 65% · Kimi 66% · DeepSeek ¥62.47),图标绿「65%」。
    static func normalState() -> EngineState {
        scenarioState(glmWeeklyRemaining: 39_000)
    }

    /// 偏低形态:GLM 7 天窗 20%(黄),他者正常,图标黄「20%」。
    static func lowState() -> EngineState {
        scenarioState(glmWeeklyRemaining: 12_000)
    }

    /// 临界形态:GLM 7 天窗 5%(红,对照原型 critical 场景),他者健康,图标红「5%」。
    static func criticalState() -> EngineState {
        scenarioState(glmWeeklyRemaining: 3_000)
    }

    /// 陈旧形态(IC-3 验收):GLM 数据 90 分钟前(超 2× 轮询间隔)、未进入加载失败态——
    /// 隔离「图标陈旧标记」与「加载失败」两条呈现路径。
    static func staleState() -> EngineState {
        scenarioState(glmWeeklyRemaining: 39_000, glmAge: 90 * 60)
    }

    /// 钥匙串读取异常形态:GLM 读取失败(状态未知,仍持旧快照)、Kimi 失效、DeepSeek 未配置。
    static func readFailureState() -> EngineState {
        var providers: [Provider: ProviderRuntimeState] = [:]
        providers[.glm] = runtime(.glm, snapshot: glm(), credential: .missing)
        providers[.kimi] = runtime(.kimi, snapshot: kimi(weekRemaining: 66), credential: .invalid)
        providers[.deepseek] = runtime(.deepseek, snapshot: nil, credential: .missing)
        return EngineState(
            providers: providers,
            lastRefreshStartedAt: Date().addingTimeInterval(-freshAge),
            credentialReadFailures: [.glm],
            overview: GlobalOverview.compute(
                snapshots: providers.compactMapValues(\.snapshot),
                evaluator: StatusEvaluator()
            )
        )
    }

    /// 口径乙验收(IC-4+IC-5):DeepSeek 余额临界 + GLM 7 天窗 65%(他者健康)——
    /// 旧口径「红 65%」混叠形态的复现场景;新口径数字应绿。
    static func deepseekCriticalWithWindowsState() -> EngineState {
        scenarioState(glmWeeklyRemaining: 39_000, deepseekTotal: "8.20")
    }

    /// DeepSeek-only 临界:仅 DeepSeek 持快照、无任何 plan-window——「彩色 —」
    /// (余额档给色)的验收形态;旧口径永久灰「—」。
    static func deepseekOnlyCriticalState() -> EngineState {
        var providers: [Provider: ProviderRuntimeState] = [:]
        providers[.glm] = runtime(.glm, snapshot: nil, credential: .missing)
        providers[.kimi] = runtime(.kimi, snapshot: nil, credential: .missing)
        providers[.deepseek] = runtime(.deepseek, snapshot: deepseek(total: "8.20"))
        return EngineState(
            providers: providers,
            lastRefreshStartedAt: Date().addingTimeInterval(-freshAge),
            lastRefreshFinishedAt: Date().addingTimeInterval(-freshAge),
            overview: GlobalOverview.compute(
                snapshots: providers.compactMapValues(\.snapshot),
                evaluator: StatusEvaluator()
            )
        )
    }

    // MARK: - 到期形态(#54)

    /// 到期场景共用构造:GLM 套餐健康(65%)、有效期与失败态按入参;他者健康。
    /// glmAge 控制 GLM 快照新旧,validity 自带 observedAt 控制有效期观测时刻
    /// (两者独立——复现「额度新鲜、只有订阅分片连续失败」的陈旧形态)。
    private static func expiryScenarioState(
        validity: PlanValidity?,
        glmAge: TimeInterval = freshAge,
        glmLoadFailed: Bool = false,
        glmConsecutiveFailures: Int = 0
    ) -> EngineState {
        var providers: [Provider: ProviderRuntimeState] = [:]
        providers[.glm] = runtime(
            .glm,
            snapshot: glm(weeklyRemaining: 39_000, validity: validity, fetchedAt: Date().addingTimeInterval(-glmAge)),
            loadFailed: glmLoadFailed,
            consecutiveFailures: glmConsecutiveFailures
        )
        providers[.kimi] = runtime(.kimi, snapshot: kimi(weekRemaining: 66))
        // 到期场景里他者保持健康(余额走 62.47),OCR 验收时唯一的形态异常就是到期本身。
        providers[.deepseek] = runtime(.deepseek, snapshot: deepseek(total: "62.47"))
        return EngineState(
            providers: providers,
            lastRefreshStartedAt: Date().addingTimeInterval(-glmAge),
            overview: GlobalOverview.compute(
                snapshots: providers.compactMapValues(\.snapshot),
                evaluator: StatusEvaluator()
            )
        )
    }

    /// GLM 自动到期:有效期 2 天前结束(订阅分片正常,观测时刻新鲜)——头部灰「已到期」、
    /// 数值灰化、无百分比/进度条;余额/钱包与近 7 天消耗不跟着灰;tab「已到期」。
    static func glmExpiredState() -> EngineState {
        expiryScenarioState(validity: validity(untilDays: -2, fromDays: -32))
    }

    /// 即将到期:剩 2 天——「有效期至」行补「(剩 2 天)」,仅文本、无第四态,
    /// 界面其它一切照常(绿「正常」照旧)。
    static func glmExpiringSoonState() -> EngineState {
        expiryScenarioState(validity: validity(untilDays: 2, fromDays: -28))
    }

    /// 到期状态未确认:已到期,但有效期观测时刻是 90 分钟前(超 2× 轮询周期)——
    /// 到期结论带归属「(有效期数据来自 …)」;额度数据本身新鲜(5 分钟前)。
    static func glmExpiredStaleState() -> EngineState {
        expiryScenarioState(validity: validity(
            untilDays: -2,
            fromDays: -32,
            observedAt: Date().addingTimeInterval(-90 * 60)
        ))
    }

    /// 到期家额度失败:已到期 + 额度接口整体失败(3 轮)——灰条「额度未能刷新
    /// (最后成功 HH:mm)」替代橙色「加载失败」条,重试入口保留。
    static func glmExpiredLoadFailedState() -> EngineState {
        expiryScenarioState(
            validity: validity(untilDays: -2, fromDays: -32),
            glmAge: 2 * 3_600,
            glmLoadFailed: true,
            glmConsecutiveFailures: 3
        )
    }
}

struct FocusCardPreviews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 12) {
            GlobalOverviewBar(state: PreviewData.overviewState())
            FocusCardView(
                provider: .glm,
                runtime: PreviewData.runtime(.glm, snapshot: PreviewData.glm(rollingUsage: .failed, weeklyRemaining: 600), status: .critical),
                model: AppModel()
            )
            FocusCardView(
                provider: .kimi,
                runtime: PreviewData.runtime(.kimi, snapshot: PreviewData.kimi()),
                model: AppModel()
            )
            FocusCardView(
                provider: .deepseek,
                runtime: PreviewData.runtime(.deepseek, snapshot: PreviewData.deepseek(), status: .critical),
                model: AppModel()
            )
        }
        .padding()
        .frame(width: 360)
    }
}

struct ErrorStatePreviews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 12) {
            FocusCardView(
                provider: .kimi,
                runtime: PreviewData.runtime(.kimi, snapshot: nil, credential: .invalid, status: .normal),
                model: AppModel()
            )
            FocusCardView(
                provider: .glm,
                runtime: PreviewData.runtime(.glm, snapshot: nil, status: .normal, loadFailed: true, consecutiveFailures: 3),
                model: AppModel()
            )
            FocusCardView(
                provider: .deepseek,
                runtime: PreviewData.runtime(.deepseek, snapshot: nil, credential: .missing),
                model: AppModel()
            )
        }
        .padding()
        .frame(width: 360)
    }
}

struct SettingsWindowPreviews: PreviewProvider {
    static var previews: some View {
        SettingsWindowView(model: AppModel())
    }
}
#endif
