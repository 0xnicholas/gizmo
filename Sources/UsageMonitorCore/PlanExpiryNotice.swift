import Foundation

/// 到期提醒三类(#57,词条见 CONTEXT「已到期」)的文案与通知去重标识:
/// - 「套餐即将到期」:距到期 ≤ `Thresholds.expiryReminderDays`;
/// - 「套餐已到期」:`now >= 有效期端点`(与 `PlanState` 同一边界);
/// - 「套餐已恢复」:到期 → 续订翻回(有效期端点推后)。
///
/// 通知文案留在 Core(先例 `UsageAlert`):家名 + 到期时刻,`autoRenew == false`
/// 时补「不自动续订」事实(响应未给该字段则不猜)。到期时刻按**北京时间**——与有效期
/// 的解析口径同一个时区常量(`PlanValidity.timeZone`),跨时区机器上「10-15 10:00」
/// 不差一天。静默键是有效期端点本身(见 `PlanExpirySilenceKeys`),不在这里。
public struct PlanExpiryNotice: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// 距到期 ≤ 提醒天数;N 由 `remainingDays(until:now:)` 算出(向上取整,不出现「剩 0 天」)。
        case approaching(daysRemaining: Int)
        /// 到期当刻(`now >= validUntil`)。
        case expired
        /// 到期 → 续订翻回。
        case renewed
    }

    public var provider: Provider
    /// 相关有效期端点:approaching / expired 是刚失效的旧端点,renewed 是新的端点。
    public var validUntil: Date
    /// provider 自报是否自动续订;nil = 响应未给该字段(文案里不出现续订断言)。
    public var autoRenew: Bool?
    public var kind: Kind

    public init(provider: Provider, validUntil: Date, autoRenew: Bool? = nil, kind: Kind) {
        self.provider = provider
        self.validUntil = validUntil
        self.autoRenew = autoRenew
        self.kind = kind
    }

    public var title: String {
        switch kind {
        case .approaching: return "套餐即将到期"
        case .expired: return "套餐已到期"
        case .renewed: return "套餐已恢复"
        }
    }

    /// 通知正文(与卡上文案同词汇:有效期至 / 已到期 / 不自动续订)。
    public var text: String {
        let moment = Self.moment(validUntil)
        switch kind {
        case .approaching(let days):
            return "\(provider.displayName) 有效期至 \(moment)(剩 \(days) 天)" + noAutoRenewClause
        case .expired:
            return "\(provider.displayName) 已于 \(moment) 到期" + noAutoRenewClause
        case .renewed:
            return "\(provider.displayName) 有效期已续至 \(moment)"
        }
    }

    /// 通知去重标识:三类互不顶掉(通知中心可对照);同一家同一类的后一条覆盖前一条
    /// (有效期换了,旧提醒已过时——再次出现是「新端点重新计时」的结果,以新为准)。
    public var notificationIdentifier: String {
        switch kind {
        case .approaching: return "plan-expiry-\(provider.rawValue)"
        case .expired: return "plan-expired-\(provider.rawValue)"
        case .renewed: return "plan-renewed-\(provider.rawValue)"
        }
    }

    /// 「剩 N 天」的唯一口径(卡上有效期行后缀与通知文案共用,两处公式不漂移):
    /// N 向上取整、最低 1(0.5 天 → 剩 1 天)。
    public static func remainingDays(until validUntil: Date, now: Date) -> Int {
        max(1, Int(ceil(validUntil.timeIntervalSince(now) / secondsPerDay)))
    }

    /// 「即将到期」提醒窗:剩余 > 0 且 ≤ 提醒天数。卡上后缀(何时补「(剩 N 天)」)
    /// 与到期通知(何时发「即将到期」)共用同一判定——两处不漂移。
    public static func isApproaching(validUntil: Date, now: Date, reminderDays: Int) -> Bool {
        let remaining = validUntil.timeIntervalSince(now)
        return remaining > 0 && remaining <= Double(reminderDays) * secondsPerDay
    }

    /// 到期时刻的展示口径:MM-dd HH:mm,北京时间(+08:00,与有效期解析同一常量)。
    static func moment(_ date: Date) -> String {
        momentFormatter.string(from: date)
    }

    /// `autoRenew == false` 才补事实;nil / true 都不出现续订断言(不猜)。
    private var noAutoRenewClause: String {
        autoRenew == false ? ",不自动续订" : ""
    }

    static let secondsPerDay: TimeInterval = 86_400

    private static let momentFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = PlanValidity.timeZone
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
