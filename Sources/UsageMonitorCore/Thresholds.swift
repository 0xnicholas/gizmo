import Foundation

/// 阈值与策略参数的集中处(spec「参数化」节)。
///
/// 默认值即 spec 决议取值;测试与将来可能的设置界面只需要换一个 `Thresholds` 实例。
public struct Thresholds: Equatable, Sendable {
    /// plan-window 剩余占比低于该值为「临界」。
    public var criticalRemainingFraction: Double
    /// plan-window 剩余占比低于该值为「偏低」。
    public var lowRemainingFraction: Double
    /// DeepSeek 无可参与判定的窗口,按余额分界:低于该值为「临界」。
    public var deepseekCriticalBalance: Decimal
    /// DeepSeek 余额低于该值为「偏低」。
    public var deepseekLowBalance: Decimal
    /// 同一家同类通知的静默窗口(状态恢复后再次跳变才重发)。
    public var notificationCooldown: TimeInterval
    /// networkError 连续失败轮数达到该值 →「加载失败」态。
    public var failureRoundsBeforeLoadFailure: Int
    /// 后台轮询周期。
    public var refreshInterval: TimeInterval
    /// 「即将到期」的提前天数:有效期剩余 ≤ 该值时,卡上有效期行补「(剩 N 天)」
    /// (#57 的到期前提醒通知共用同一阈值)。
    public var expiryReminderDays: Int
    /// 到期结论的陈旧阈值:有效期观测时刻距 now 超过该值时,到期结论带归属时刻
    /// (默认 2× 默认轮询周期 = 60 分钟;连续失败超过约两轮即触发)。
    public var expiryStalenessThreshold: TimeInterval

    public init(
        criticalRemainingFraction: Double = 0.10,
        lowRemainingFraction: Double = 0.30,
        deepseekCriticalBalance: Decimal = 10,
        deepseekLowBalance: Decimal = 50,
        notificationCooldown: TimeInterval = 24 * 60 * 60,
        failureRoundsBeforeLoadFailure: Int = 3,
        refreshInterval: TimeInterval = 30 * 60,
        expiryReminderDays: Int = 3,
        expiryStalenessThreshold: TimeInterval = 2 * 30 * 60
    ) {
        self.criticalRemainingFraction = criticalRemainingFraction
        self.lowRemainingFraction = lowRemainingFraction
        self.deepseekCriticalBalance = deepseekCriticalBalance
        self.deepseekLowBalance = deepseekLowBalance
        self.notificationCooldown = notificationCooldown
        self.failureRoundsBeforeLoadFailure = failureRoundsBeforeLoadFailure
        self.refreshInterval = refreshInterval
        self.expiryReminderDays = expiryReminderDays
        self.expiryStalenessThreshold = expiryStalenessThreshold
    }
}
