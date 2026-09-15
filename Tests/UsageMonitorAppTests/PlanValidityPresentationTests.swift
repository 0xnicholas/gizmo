import Foundation
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// 套餐有效期行的呈现口径(#53):有效期串按北京时间(+08:00)解析,展示也用同一时区——
/// 若随系统时区走,跨时区机器上「有效期至」会差一天。卡上只出现 MM-dd(年月由解析层与
/// 调研文档的实测区间给定,行内不再复述)。
@Suite("套餐有效期行呈现(#53)")
struct PlanValidityPresentationTests {
    @Test("按北京时间归日:UTC 前一日 20:00 已是北京次日 04:00")
    func formatsInBeijingTime() {
        // 2026-10-14 20:00Z = 2026-10-15 04:00 +08:00;2026-10-15 17:00Z = 2026-10-16 01:00 +08:00。
        #expect(Presentation.validityDate(Date(timeIntervalSince1970: 1_792_008_000)) == "10-15")
        #expect(Presentation.validityDate(Date(timeIntervalSince1970: 1_792_083_600)) == "10-16")
    }

    @Test("月日补零:实测区间两端各自归日(2026-09-15 10:00 / 2026-10-15 10:00 +08:00)")
    func padsMonthAndDay() {
        #expect(Presentation.validityDate(Date(timeIntervalSince1970: 1_789_437_600)) == "09-15")
        #expect(Presentation.validityDate(Date(timeIntervalSince1970: 1_792_029_600)) == "10-15")
    }
}

/// 到期态的呈现文案(#54):即将到期后缀、到期结论的陈旧归属、到期档文案。
/// 陈旧是展示属性(不引入第四态):只在到期结论旁附归属时刻,不改变状态取值。
@Suite("到期态呈现(#54)")
struct PlanExpiryPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)  // 2026-10-14 20:26 UTC

    // MARK: - 即将到期后缀

    @Test("剩余 ≤ 3 天补「(剩 N 天)」;N 向上取整(2.5 天 → 剩 3 天)")
    func expiringSoonSuffixWithinWindow() {
        #expect(Presentation.expiringSoonSuffix(validUntil: now.addingTimeInterval(3 * 86_400), now: now, reminderDays: 3) == "(剩 3 天)")
        #expect(Presentation.expiringSoonSuffix(validUntil: now.addingTimeInterval(2.5 * 86_400), now: now, reminderDays: 3) == "(剩 3 天)")
        #expect(Presentation.expiringSoonSuffix(validUntil: now.addingTimeInterval(0.5 * 86_400), now: now, reminderDays: 3) == "(剩 1 天)")
    }

    @Test("剩余 > 提醒天数或已到期 → nil(后缀不出现;到期走灰化形态)")
    func expiringSoonSuffixOutsideWindow() {
        #expect(Presentation.expiringSoonSuffix(validUntil: now.addingTimeInterval(3.01 * 86_400), now: now, reminderDays: 3) == nil)
        #expect(Presentation.expiringSoonSuffix(validUntil: now.addingTimeInterval(30 * 86_400), now: now, reminderDays: 3) == nil)
        #expect(Presentation.expiringSoonSuffix(validUntil: now, now: now, reminderDays: 3) == nil)
        #expect(Presentation.expiringSoonSuffix(validUntil: now.addingTimeInterval(-86_400), now: now, reminderDays: 3) == nil)
    }

    @Test("阈值参数化:提醒天数可换实例")
    func expiringSoonThresholdInjectable() {
        #expect(Presentation.expiringSoonSuffix(validUntil: now.addingTimeInterval(5 * 86_400), now: now, reminderDays: 7) == "(剩 5 天)")
        #expect(Presentation.expiringSoonSuffix(validUntil: now.addingTimeInterval(5 * 86_400), now: now, reminderDays: 3) == nil)
    }

    // MARK: - 陈旧归属

    @Test("观测时刻距 now 超过阈值 → 「(有效期数据来自 MM-dd HH:mm)」;恰好等于阈值不算")
    func staleAttribution() {
        let observed = now.addingTimeInterval(-3_601)
        let expected = "(有效期数据来自 \(Presentation.observedMoment(observed)))"
        #expect(Presentation.staleValidityAttribution(observedAt: observed, now: now, threshold: 3_600) == expected)
        #expect(Presentation.staleValidityAttribution(observedAt: now.addingTimeInterval(-3_600), now: now, threshold: 3_600) == nil)
        #expect(Presentation.staleValidityAttribution(observedAt: now.addingTimeInterval(-60), now: now, threshold: 3_600) == nil)
        // 时钟倒漂(观测时刻在未来)不算陈旧,与相对时间分档的防御口径一致
        #expect(Presentation.staleValidityAttribution(observedAt: now.addingTimeInterval(60), now: now, threshold: 3_600) == nil)
    }

    @Test("到期档文案:卡头与 tab 共用同一常量")
    func expiredLabelShared() {
        #expect(Presentation.planExpiredLabel == "已到期")
    }
}
