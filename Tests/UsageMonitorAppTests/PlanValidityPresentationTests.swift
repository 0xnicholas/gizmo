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
