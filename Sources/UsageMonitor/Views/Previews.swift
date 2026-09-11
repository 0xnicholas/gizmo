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
        status: ProviderStatus = .normal,
        loadFailed: Bool = false,
        consecutiveFailures: Int = 0
    ) -> ProviderRuntimeState {
        var runtime = ProviderRuntimeState(provider: provider)
        runtime.snapshot = snapshot
        runtime.credential = credential
        runtime.status = status
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

    static func overviewState() -> EngineState {
        var providers: [Provider: ProviderRuntimeState] = [:]
        let glmSnapshot = glm()
        providers[.glm] = runtime(.glm, snapshot: glmSnapshot, status: .normal)
        providers[.kimi] = runtime(.kimi, snapshot: kimi(dayRemaining: 66), status: .normal)
        providers[.deepseek] = runtime(.deepseek, snapshot: deepseek(), status: .critical)
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
