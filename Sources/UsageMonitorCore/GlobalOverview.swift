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
    /// 已到期的家(#56,按 `Provider.allCases` 序):退出最紧/最差/图标数字,
    /// 但由呈现层的「已到期:」行与图标 a11y 承认——退出口径的家在结论区不留痕,
    /// 用户就只能逐个 tab 找。到期是持快照家的属性,无快照者不入此表。
    public var expiredProviders: [Provider]

    public init(
        tightest: Tightest? = nil,
        worstStatus: ProviderStatus? = nil,
        snapshotCount: Int = 0,
        expiredProviders: [Provider] = []
    ) {
        self.tightest = tightest
        self.worstStatus = worstStatus
        self.snapshotCount = snapshotCount
        self.expiredProviders = expiredProviders
    }

    /// 菜单栏图标数字:nil = 灰「—」(没有任何 plan-window 数据)。
    /// 口径见 `Percent.display`。
    public var iconPercent: Int? {
        tightest.map { Percent.display($0.fraction) }
    }

    /// 生产入口:快照 + now 现场求值 planState(与卡/tab 同一判定函数)。
    /// DeepSeek 恒 unknown(余额型家不做到期断言),不会经此入口被剔除。
    public static func compute(
        snapshots: [Provider: Snapshot],
        evaluator: StatusEvaluator,
        now: Date
    ) -> GlobalOverview {
        compute(
            snapshots: snapshots,
            evaluator: evaluator,
            planStates: Dictionary(uniqueKeysWithValues: Provider.allCases.map {
                ($0, PlanState.evaluate(provider: $0, snapshot: snapshots[$0], now: now))
            })
        )
    }

    /// 注入入口:测试/预览直接给定 planState(可构造生产不可达的形态,
    /// 如「三家全到期」——DeepSeek 现实恒 unknown)。缺失的 provider 视为 unknown。
    public static func compute(
        snapshots: [Provider: Snapshot],
        evaluator: StatusEvaluator,
        planStates: [Provider: PlanState]
    ) -> GlobalOverview {
        var tightest: Tightest?
        var worst: ProviderStatus?
        var count = 0
        var expired: [Provider] = []

        for provider in Provider.allCases {
            guard let snapshot = snapshots[provider] else { continue }
            count += 1
            // 到期退出全局结论(#56):已经不能用的额度不当「现在还能用多少」的结论,
            // 也不拉低全局最差——但记入 expiredProviders 供结论区承认。
            if planStates[provider]?.isExpired == true {
                expired.append(provider)
                continue
            }
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

        return GlobalOverview(
            tightest: tightest,
            worstStatus: worst,
            snapshotCount: count,
            expiredProviders: expired
        )
    }
}
