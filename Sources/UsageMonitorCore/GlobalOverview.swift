import Foundation

/// 全局汇总口径:菜单栏图标数字与 popover 顶部「全局最紧」条共用同一个值(spec 用户故事 18)。
public struct GlobalOverview: Equatable, Sendable {
    /// 全局最紧的 plan-window:全部 provider 的 plan-window 中剩余占比最低者。
    public struct Tightest: Equatable, Sendable {
        public var provider: Provider
        public var windowLabel: String
        public var unit: String
        public var limit: Int
        public var remaining: Int
        public var fraction: Double
        public var resetAt: Date?

        /// 与菜单栏图标同源的展示百分比(总览条与图标共用,两处数字不打架)。
        public var displayPercent: Int { Percent.display(fraction) }

        public init(
            provider: Provider,
            windowLabel: String,
            unit: String,
            limit: Int,
            remaining: Int,
            fraction: Double,
            resetAt: Date?
        ) {
            self.provider = provider
            self.windowLabel = windowLabel
            self.unit = unit
            self.limit = limit
            self.remaining = remaining
            self.fraction = fraction
            self.resetAt = resetAt
        }
    }

    public var tightest: Tightest?
    /// 全局最差 status(含 DeepSeek 余额分界);没有任何快照时为 nil。
    public var worstStatus: ProviderStatus?
    /// 参与判定的 provider 数(持有快照者)。
    public var snapshotCount: Int

    public init(tightest: Tightest? = nil, worstStatus: ProviderStatus? = nil, snapshotCount: Int = 0) {
        self.tightest = tightest
        self.worstStatus = worstStatus
        self.snapshotCount = snapshotCount
    }

    /// 菜单栏图标数字:nil = 灰「—」(没有任何 plan-window 数据)。
    /// 口径见 `Percent.display`。
    public var iconPercent: Int? {
        tightest.map { Percent.display($0.fraction) }
    }

    public static func compute(
        snapshots: [Provider: Snapshot],
        evaluator: StatusEvaluator
    ) -> GlobalOverview {
        var tightest: Tightest?
        var worst: ProviderStatus?
        var count = 0

        for provider in Provider.allCases {
            guard let snapshot = snapshots[provider] else { continue }
            count += 1
            worst = ProviderStatus.worst(worst ?? .normal, evaluator.status(for: snapshot))
            for window in snapshot.planWindows {
                guard let fraction = window.remainingFraction else { continue }
                if let current = tightest, current.fraction <= fraction { continue }
                tightest = Tightest(
                    provider: provider,
                    windowLabel: window.label,
                    unit: window.unit,
                    limit: window.limit,
                    remaining: window.remaining,
                    fraction: fraction,
                    resetAt: window.resetAt
                )
            }
        }

        return GlobalOverview(tightest: tightest, worstStatus: worst, snapshotCount: count)
    }
}
