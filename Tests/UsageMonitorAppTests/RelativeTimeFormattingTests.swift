import Foundation
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// 相对时间分档(骨架F+FC-1,#37):重置倒计时 <1h 分钟档 / <24h 小时档 / 跨天绝对档;
/// 「上次更新」<1h 相对化、≥1h 退回绝对。倒计时/相对档都向下取整(与「还有多久」的读法一致)。
/// 失败态旧快照的「已过期」标注是卡片层逻辑(由 render-previews OCR 验收),不在此测。
@Suite("相对时间分档(骨架F+FC-1)")
struct RelativeTimeFormattingTests {
    /// 固定基准时刻:绝对档只断言与 formatter 同形,不断言具体日期串。
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func after(_ interval: TimeInterval) -> Date {
        Self.now.addingTimeInterval(interval)
    }

    // MARK: - 重置倒计时

    @Test("59 分钟 → 分钟档;30 秒 → 最低 1 分钟")
    func countdownMinuteTier() {
        #expect(Presentation.resetCountdown(after(59 * 60), now: Self.now) == "约 59 分钟后重置")
        #expect(Presentation.resetCountdown(after(30), now: Self.now) == "约 1 分钟后重置")
    }

    @Test("1 小时整 → 小时档;90 分钟 → 向下取整 1 小时;23 小时 → 仍小时档")
    func countdownHourTier() {
        #expect(Presentation.resetCountdown(after(3_600), now: Self.now) == "约 1 小时后重置")
        #expect(Presentation.resetCountdown(after(90 * 60), now: Self.now) == "约 1 小时后重置")
        #expect(Presentation.resetCountdown(after(23 * 3_600), now: Self.now) == "约 23 小时后重置")
    }

    @Test("24 小时整与跨天 → 绝对日期;已过期(非失败态)→ 绝对日期兜底")
    func countdownAbsoluteTier() {
        let day = Presentation.resetCountdown(after(86_400), now: Self.now)
        let days = Presentation.resetCountdown(after(3 * 86_400), now: Self.now)
        let past = Presentation.resetCountdown(after(-60), now: Self.now)
        #expect(day == Presentation.absoluteReset(after(86_400)))
        #expect(days == Presentation.absoluteReset(after(3 * 86_400)))
        #expect(past == Presentation.absoluteReset(after(-60)))
        #expect(day.hasPrefix("重置 "))
    }

    // MARK: - 上次更新相对化

    @Test("<1h → 「N 分钟前更新」;10 秒 → 最低 1 分钟")
    func updatedAgoMinutes() {
        #expect(Presentation.updatedAgo(after(-30 * 60), now: Self.now) == "30 分钟前更新")
        #expect(Presentation.updatedAgo(after(-59 * 60), now: Self.now) == "59 分钟前更新")
        #expect(Presentation.updatedAgo(after(-10), now: Self.now) == "1 分钟前更新")
    }

    @Test("≥1h 退回绝对「上次更新 HH:mm」")
    func updatedAgoAbsolute() {
        let oneHour = Presentation.updatedAgo(after(-3_600), now: Self.now)
        let threeHours = Presentation.updatedAgo(after(-3 * 3_600), now: Self.now)
        #expect(oneHour == "上次更新 " + Presentation.time(after(-3_600)))
        #expect(threeHours == "上次更新 " + Presentation.time(after(-3 * 3_600)))
        #expect(oneHour.contains("分钟前") == false)
    }
}
