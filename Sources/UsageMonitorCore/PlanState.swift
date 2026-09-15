import Foundation

/// 套餐到期判定(#54,词条见 CONTEXT「已到期」):`planValidity` 与 now 的**纯求值**,
/// 外加用户手动声明的入口(#58):
/// `active` / `expired`(provider 侧订阅记录)/ `manuallyExpired`(用户声明)/ `unknown`。
///
/// 到期**不进健康状态档**(「还适不适用」不是「还够不够用」,与 `accountAvailable`
/// 同型的正交事实),也不引入第四种 status;DeepSeek 恒 `unknown`。
/// 陈旧(observedAt 距 now 超过阈值)是**展示属性**,不是第四态——由呈现层
/// 给到期结论附归属时刻,不改变这里的取值。
public enum PlanState: Equatable, Sendable {
    /// 有效期内。`autoRenew` 只作展示与(#57 的)通知事实,不参与判定。
    case active(validUntil: Date, autoRenew: Bool?, observedAt: Date)
    /// 已到期:`now >= validUntil`(到期时刻当刻失效)。
    case expired(validUntil: Date, observedAt: Date)
    /// 用户手动标记为已到期(#58):没有 provider 有效期,归属时刻 = 标记时刻。
    /// 只在 provider 侧无结论、且该家提供手动入口(`Provider.supportsManualPlanExpiry`)时成立。
    case manuallyExpired(markedAt: Date)
    /// 无到期断言:无来源 / 从未成功 / 未手动标记。
    case unknown
}

extension PlanState {
    /// 便捷判定:是否为 expired(卡/tab 灰化形态的成立条件之一;
    /// 凭据优先于到期的门控在呈现层,见 `Presentation` / 焦点卡)。手动态同属到期。
    public var isExpired: Bool {
        switch self {
        case .expired, .manuallyExpired: return true
        case .active, .unknown: return false
        }
    }

    /// 快照 + 手动声明 → planState。判定只看有效期末端与 now,不猜、不推断
    /// (窗口消失 / 数字停滞都不是到期证据,见 CONTEXT「planValidity 套餐有效期」)。
    ///
    /// 判定顺序(#58):**provider 侧优先**——有订阅记录时以记录为准,手动声明永不覆盖
    /// (「自动来源说 active 时不会被手动标记盖掉」);provider 侧无结论时才轮到手动声明,
    /// 且只认有手动入口的家。
    ///
    /// - DeepSeek 恒 `unknown`:无套餐窗口的余额型 provider 不做到期断言(spec 定死,
    ///   防解析层未来误挂;手动声明也不在这套机制里)。
    /// - `observedAt` 优先取有效期自身的观测时刻(跨订阅分片失败保留时**不动**,
    ///   陈旧标注靠它);#54 前的旧缓存没有该字段,回退快照 fetchedAt——那份快照
    ///   就是当时的成功取得。
    public static func evaluate(
        provider: Provider,
        snapshot: Snapshot?,
        manualExpiry: ManualPlanExpiry?,
        now: Date
    ) -> PlanState {
        if provider != .deepseek, let snapshot, let validity = snapshot.planValidity {
            let observedAt = validity.observedAt ?? snapshot.meta.fetchedAt
            if now >= validity.validUntil {
                return .expired(validUntil: validity.validUntil, observedAt: observedAt)
            }
            return .active(
                validUntil: validity.validUntil,
                autoRenew: validity.autoRenew,
                observedAt: observedAt
            )
        }
        // 有自动来源的家即使当前取不到有效期(GLM 分片失败)也不接受手动声明:
        // 「不提供手动覆盖」是入口的适用面,不是「取到时才优先」。
        if provider.supportsManualPlanExpiry, let manualExpiry {
            return .manuallyExpired(markedAt: manualExpiry.markedAt)
        }
        return .unknown
    }

    /// 运行时态入口(引擎与 UI 的共享口径):手动声明就在运行态里,
    /// 判定只在 `evaluate(provider:snapshot:manualExpiry:now:)` 一处,两处不各拼一次。
    public static func evaluate(runtime: ProviderRuntimeState, now: Date) -> PlanState {
        evaluate(
            provider: runtime.provider,
            snapshot: runtime.snapshot,
            manualExpiry: runtime.manualPlanExpiry,
            now: now
        )
    }
}
