import Foundation
import Testing
@testable import UsageMonitorCore

/// 到期提醒三类的文案与通知去重标识(#57):前 3 天 / 当刻 / 续订恢复。
/// 文案口径与卡上一致(家名 + 到期时刻;剩 N 天向上取整),到期时刻按北京时间
/// ——与有效期的解析口径同一个时区常量,不随系统时区漂移。
@Suite("到期提醒文案(#57)")
struct PlanExpiryNoticeCopyTests {
    /// 实测区间末端:2026-10-15 10:00 +08:00。
    private let validUntil = Date(timeIntervalSince1970: 1_792_029_600)

    @Test("即将到期:家名 + 到期时刻 + 剩 N 天 + 不自动续订")
    func approachingCopy() {
        let notice = PlanExpiryNotice(
            provider: .glm,
            validUntil: validUntil,
            autoRenew: false,
            kind: .approaching(daysRemaining: 3)
        )
        #expect(notice.title == "套餐即将到期")
        #expect(notice.text == "GLM Coding Plan 有效期至 10-15 10:00(剩 3 天),不自动续订")
        #expect(notice.notificationIdentifier == "plan-expiry-glm")
    }

    @Test("已到期:家名 + 到期时刻 + 不自动续订")
    func expiredCopy() {
        let notice = PlanExpiryNotice(
            provider: .glm,
            validUntil: validUntil,
            autoRenew: false,
            kind: .expired
        )
        #expect(notice.title == "套餐已到期")
        #expect(notice.text == "GLM Coding Plan 已于 10-15 10:00 到期,不自动续订")
        #expect(notice.notificationIdentifier == "plan-expired-glm")
    }

    @Test("已恢复:家名 + 新有效期时刻(续订后的端点)")
    func renewedCopy() {
        let notice = PlanExpiryNotice(
            provider: .kimi,
            validUntil: Date(timeIntervalSince1970: 1_794_708_000),  // 2026-11-15 10:00 +08:00
            autoRenew: true,
            kind: .renewed
        )
        #expect(notice.title == "套餐已恢复")
        #expect(notice.text == "Kimi for Coding 有效期已续至 11-15 10:00")
        #expect(notice.notificationIdentifier == "plan-renewed-kimi")
    }

    @Test("「不自动续订」只在明确为 false 时出现;nil(响应未给)与 true 都不猜")
    func autoRenewClauseOnlyWhenFalse() {
        func approaching(_ autoRenew: Bool?) -> String {
            PlanExpiryNotice(provider: .glm, validUntil: validUntil, autoRenew: autoRenew, kind: .approaching(daysRemaining: 2)).text
        }
        func expired(_ autoRenew: Bool?) -> String {
            PlanExpiryNotice(provider: .glm, validUntil: validUntil, autoRenew: autoRenew, kind: .expired).text
        }
        #expect(approaching(nil) == "GLM Coding Plan 有效期至 10-15 10:00(剩 2 天)")
        #expect(expired(nil) == "GLM Coding Plan 已于 10-15 10:00 到期")
        #expect(approaching(true).hasSuffix("不自动续订") == false)
        #expect(expired(true).hasSuffix("不自动续订") == false)
    }

    @Test("三类 identifier 互不顶掉(通知中心可对照);同一家不同有效期共用同类标识(自然覆盖旧条)")
    func identifiersDistinguishKinds() {
        let kinds: [PlanExpiryNotice.Kind] = [.approaching(daysRemaining: 1), .expired, .renewed]
        let identifiers = kinds.map {
            PlanExpiryNotice(provider: .glm, validUntil: validUntil, kind: $0).notificationIdentifier
        }
        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers.allSatisfy { $0.contains("glm") })
    }

    @Test("到期时刻按北京时间归时(与有效期解析同一时区常量)")
    func momentUsesBeijingTime() {
        // 2026-10-15 02:00 UTC = 2026-10-15 10:00 +08:00
        let notice = PlanExpiryNotice(
            provider: .glm,
            validUntil: Date(timeIntervalSince1970: 1_792_029_600),
            kind: .expired
        )
        #expect(notice.text.contains("10-15 10:00"))
    }
}

/// 「剩 N 天」的唯一口径(#57):通知文案与卡上有效期行后缀共用,
/// 两处公式不漂移(0.5 天 → 剩 1 天,不出现「剩 0 天」)。
@Suite("剩余天数口径(#57)")
struct PlanExpiryRemainingDaysTests {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    @Test("向上取整且最低 1 天")
    func roundsUp() {
        #expect(PlanExpiryNotice.remainingDays(until: now.addingTimeInterval(0.5 * 86_400), now: now) == 1)
        #expect(PlanExpiryNotice.remainingDays(until: now.addingTimeInterval(1.0 * 86_400), now: now) == 1)
        #expect(PlanExpiryNotice.remainingDays(until: now.addingTimeInterval(2.5 * 86_400), now: now) == 3)
        #expect(PlanExpiryNotice.remainingDays(until: now.addingTimeInterval(3.0 * 86_400), now: now) == 3)
    }
}
