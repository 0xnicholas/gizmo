#if DEBUG
import SwiftUI
import UsageMonitorCore

/// 手动验收用的样例数据(占位值,不发网络请求)。原型形态见 `prototype/*` 分支。
enum PreviewData {
    static let fetchedAt = Date(timeIntervalSince1970: 1_789_000_000)

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

    static func glm(rollingUsage: RollingUsage? = .value(amount: 7_500_000, unit: "tokens"), weeklyRemaining: Int = 15_929) -> Snapshot {
        Snapshot(
            meta: SnapshotMeta(provider: .glm, plan: Plan(level: "pro"), fetchedAt: fetchedAt, concurrencyLimit: nil),
            windows: [
                QuotaWindow(kind: .planWindow, label: "5 小时窗", unit: "积分", limit: 12_000, used: 641, remaining: 11_358, resetAt: fetchedAt.addingTimeInterval(3_600)),
                QuotaWindow(kind: .planWindow, label: "7 天窗", unit: "积分", limit: 60_000, used: 60_000 - weeklyRemaining, remaining: weeklyRemaining, resetAt: fetchedAt.addingTimeInterval(3 * 86_400)),
            ],
            balances: [],
            rollingUsage: rollingUsage,
            raw: "{}"
        )
    }

    static func kimi(dayRemaining: Int = 66) -> Snapshot {
        Snapshot(
            meta: SnapshotMeta(provider: .kimi, plan: Plan(level: "Allegretto", domain: "DOMAIN_NEXUS"), fetchedAt: fetchedAt, concurrencyLimit: 20),
            windows: [
                QuotaWindow(kind: .planWindow, label: "日窗口", unit: "会话", limit: 100, used: 100 - dayRemaining, remaining: dayRemaining, resetAt: fetchedAt.addingTimeInterval(8 * 3_600)),
                QuotaWindow(kind: .rateLimit, label: "频限 · 滚动窗(300 分钟)", unit: "请求", limit: 100, used: 10, remaining: 90, resetAt: fetchedAt.addingTimeInterval(1_800)),
            ],
            balances: [Balance(type: .wallet, amount: Decimal(string: "3.5")!, currency: "CNY")],
            rollingUsage: nil,
            raw: "{}"
        )
    }

    static func deepseek(total: String = "8.20") -> Snapshot {
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

    /// 错误形态:Kimi 凭据失效、GLM 加载失败(仍持有旧数据)、DeepSeek 未配置。
    static func errorState() -> EngineState {
        var providers: [Provider: ProviderRuntimeState] = [:]
        providers[.glm] = runtime(
            .glm,
            snapshot: glm(rollingUsage: .failed, weeklyRemaining: 2_000),
            loadFailed: true,
            consecutiveFailures: 3
        )
        providers[.kimi] = runtime(.kimi, snapshot: kimi(dayRemaining: 66), credential: .invalid)
        providers[.deepseek] = runtime(.deepseek, snapshot: nil, credential: .missing)
        return EngineState(
            providers: providers,
            lastRefreshStartedAt: fetchedAt,
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
        providers[.kimi] = runtime(.kimi, snapshot: kimi(dayRemaining: 66))
        providers[.deepseek] = runtime(.deepseek, snapshot: deepseek())
        return EngineState(
            providers: providers,
            lastRefreshStartedAt: fetchedAt,
            lastRefreshFinishedAt: fetchedAt,
            overview: GlobalOverview.compute(
                snapshots: providers.compactMapValues(\.snapshot),
                evaluator: StatusEvaluator()
            )
        )
    }

    /// 场景形态共用构造:GLM 7 天窗剩余按入参取档,他者健康。
    private static func scenarioState(glmWeeklyRemaining: Int) -> EngineState {
        var providers: [Provider: ProviderRuntimeState] = [:]
        providers[.glm] = runtime(.glm, snapshot: glm(weeklyRemaining: glmWeeklyRemaining))
        providers[.kimi] = runtime(.kimi, snapshot: kimi(dayRemaining: 66))
        providers[.deepseek] = runtime(.deepseek, snapshot: deepseek(total: "62.47"))
        return EngineState(
            providers: providers,
            lastRefreshStartedAt: fetchedAt,
            lastRefreshFinishedAt: fetchedAt,
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

    /// 钥匙串读取异常形态:GLM 读取失败(状态未知,仍持旧快照)、Kimi 失效、DeepSeek 未配置。
    static func readFailureState() -> EngineState {
        var providers: [Provider: ProviderRuntimeState] = [:]
        providers[.glm] = runtime(.glm, snapshot: glm(), credential: .missing)
        providers[.kimi] = runtime(.kimi, snapshot: kimi(dayRemaining: 66), credential: .invalid)
        providers[.deepseek] = runtime(.deepseek, snapshot: nil, credential: .missing)
        return EngineState(
            providers: providers,
            lastRefreshStartedAt: fetchedAt,
            credentialReadFailures: [.glm],
            overview: GlobalOverview.compute(
                snapshots: providers.compactMapValues(\.snapshot),
                evaluator: StatusEvaluator()
            )
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
