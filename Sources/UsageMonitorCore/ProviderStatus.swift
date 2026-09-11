import Foundation

/// provider 级健康状态。只由快照推导,UI 只消费不计算。
public enum ProviderStatus: String, Codable, Sendable, CaseIterable {
    case normal
    case low
    case critical

    /// 数值越大越差,便于取「全局最差」。
    public var severity: Int {
        switch self {
        case .normal: return 0
        case .low: return 1
        case .critical: return 2
        }
    }

    public static func worst(_ lhs: ProviderStatus, _ rhs: ProviderStatus) -> ProviderStatus {
        lhs.severity >= rhs.severity ? lhs : rhs
    }
}

/// status 推导规则(见 CONTEXT「status 健康状态」与 spec「领域模型」)。
///
/// - 有 plan-window 的 provider:取全部 plan-window 剩余占比的最低值套档位;
///   rate-limit 频限窗不参与判定,只在卡片展示。
/// - 无窗口的 provider(DeepSeek):按余额分界(阈值参数化)。
public struct StatusEvaluator: Sendable {
    public var thresholds: Thresholds

    public init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    public func status(for snapshot: Snapshot) -> ProviderStatus {
        if snapshot.meta.accountAvailable == false {
            return .critical
        }
        if let fraction = lowestPlanWindowFraction(in: snapshot) {
            return status(forRemainingFraction: fraction)
        }
        if let total = snapshot.primaryCurrencyTotal {
            return status(forBalance: total)
        }
        return .normal
    }

    /// 剩余占比套档位:临界 < criticalRemainingFraction ≤ 偏低 < lowRemainingFraction ≤ 正常。
    public func status(forRemainingFraction fraction: Double) -> ProviderStatus {
        if fraction < thresholds.criticalRemainingFraction { return .critical }
        if fraction < thresholds.lowRemainingFraction { return .low }
        return .normal
    }

    /// 余额分界:临界 < deepseekCriticalBalance ≤ 偏低 < deepseekLowBalance ≤ 正常。
    public func status(forBalance total: Decimal) -> ProviderStatus {
        if total < thresholds.deepseekCriticalBalance { return .critical }
        if total < thresholds.deepseekLowBalance { return .low }
        return .normal
    }

    /// 全部 plan-window 剩余占比的最低值;没有 plan-window 时 nil。
    public func lowestPlanWindowFraction(in snapshot: Snapshot) -> Double? {
        snapshot.planWindows.compactMap(\.remainingFraction).min()
    }
}
