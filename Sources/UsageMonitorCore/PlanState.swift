import Foundation

/// 套餐到期判定(#54,词条见 CONTEXT「已到期」):`planValidity` 与 now 的**纯求值**,
/// 形状为三态 + 来源 + 观测时刻。
///
/// 到期**不进健康状态档**(「还适不适用」不是「还够不够用」,与 `accountAvailable`
/// 同型的正交事实),也不引入第四种 status;DeepSeek 恒 `unknown`。
/// 陈旧(observedAt 距 now 超过阈值)是**展示属性**,不是第四态——由呈现层
/// 给到期结论附归属时刻,不改变这里的取值。
public enum PlanState: Equatable, Sendable {
    /// 有效期内。`autoRenew` 只作展示与(#57 的)通知事实,不参与判定。
    case active(source: Source, validUntil: Date, autoRenew: Bool?, observedAt: Date)
    /// 已到期:`now >= validUntil`(到期时刻当刻失效)。
    case expired(source: Source, validUntil: Date, observedAt: Date)
    /// 无到期断言:无来源 / 从未成功 / 未手动标记(#58 前 manual 来源尚不存在)。
    case unknown

    /// 判据来源:provider 侧订阅记录,或(#58)用户手动标记。
    public enum Source: Equatable, Sendable {
        case provider
        case manual
    }
}

extension PlanState {
    /// 便捷判定:是否为 expired(卡/tab 灰化形态的成立条件之一;
    /// 凭据优先于到期的门控在呈现层,见 `Presentation` / 焦点卡)。
    public var isExpired: Bool {
        if case .expired = self { return true }
        return false
    }

    /// 快照 → planState。判定只看有效期末端与 now,不猜、不推断
    /// (窗口消失 / 数字停滞都不是到期证据,见 CONTEXT「planValidity 套餐有效期」)。
    ///
    /// - DeepSeek 恒 `unknown`:无套餐窗口的余额型 provider 不做到期断言(spec 定死,
    ///   防解析层未来误挂)。
    /// - `observedAt` 优先取有效期自身的观测时刻(跨订阅分片失败保留时**不动**,
    ///   陈旧标注靠它);#54 前的旧缓存没有该字段,回退快照 fetchedAt——那份快照
    ///   就是当时的成功取得。
    public static func evaluate(provider: Provider, snapshot: Snapshot?, now: Date) -> PlanState {
        guard provider != .deepseek, let snapshot, let validity = snapshot.planValidity else {
            return .unknown
        }
        let observedAt = validity.observedAt ?? snapshot.meta.fetchedAt
        if now >= validity.validUntil {
            return .expired(source: .provider, validUntil: validity.validUntil, observedAt: observedAt)
        }
        return .active(
            source: .provider,
            validUntil: validity.validUntil,
            autoRenew: validity.autoRenew,
            observedAt: observedAt
        )
    }
}
