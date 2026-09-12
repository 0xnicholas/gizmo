import Foundation
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// Kimi 卡分层与胶囊整备(P2-6+P2-9,#44):
/// - 频限窗从主区(进度条 + 「重置」倒计时)降为次级单行——「频限 剩余/总量 单位 ·
///   滚动跨度 · 容量恢复 HH:mm」,不沿用「重置」一词(滚动窗是容量滑出恢复,
///   不是额度重置);滚动跨度取自解析层 label 的括号段,缺失时省略。
/// - 套餐胶囊只显 level;内部域码进 tooltip,已知值展示层映射(DOMAIN_NEXUS→Nexus)。
@Suite("Kimi 卡分层与胶囊(P2-6+P2-9)")
struct KimiCardLayeringTests {
    private static let resetAt = Date(timeIntervalSince1970: 1_789_000_000)

    private func rateLimitWindow(
        label: String = "频限 · 滚动窗(300 分钟)",
        limit: Int = 100,
        used: Int = 10,
        remaining: Int = 90,
        resetAt: Date? = KimiCardLayeringTests.resetAt
    ) -> QuotaWindow {
        QuotaWindow(kind: .rateLimit, label: label, unit: "请求", limit: limit, used: used, remaining: remaining, resetAt: resetAt)
    }

    // MARK: - 频限次级单行

    @Test("完整单行:频限 剩余/总量 单位 · 滚动跨度 · 容量恢复绝对时刻;无「重置」;tooltip 带日期消歧")
    func rateLimitSingleLine() {
        let line = RateLimitFactLine(window: rateLimitWindow())
        #expect(line.text == "频限 90/100 请求 · 滚动 300 分钟 · 容量恢复 \(Presentation.time(Self.resetAt))")
        #expect(!line.text.contains("重置"))
        // tooltip = 带日期的完整时刻(MM-dd HH:mm 形态),不用「重置」推辞
        #expect(line.help == Presentation.recoveryMoment(Self.resetAt))
        #expect(line.help!.contains("容量恢复 "))
        #expect(line.help!.contains("-"))
        #expect(line.help!.contains(":"))
        #expect(!line.help!.contains("重置"))
    }

    @Test("label 无括号段(解析层 fallback)时省略滚动跨度,其余段保留")
    func fallbackLabelOmitsSpan() {
        let line = RateLimitFactLine(window: rateLimitWindow(label: "频限 · 滚动窗"))
        #expect(line.text == "频限 90/100 请求 · 容量恢复 \(Presentation.time(Self.resetAt))")
    }

    @Test("resetAt 缺失时省略容量恢复段")
    func missingResetAtOmitsRecovery() {
        let line = RateLimitFactLine(window: rateLimitWindow(resetAt: nil))
        #expect(line.text == "频限 90/100 请求 · 滚动 300 分钟")
    }

    @Test("失败态快照且恢复时刻已过:降级为「容量恢复已过期(最后成功快照)」(与主区 resetLine 同语义)")
    func failedSnapshotExpiredRecoveryDegrades() {
        let past = Self.resetAt.addingTimeInterval(-3_600)
        let line = RateLimitFactLine(window: rateLimitWindow(resetAt: past), fromFailedSnapshot: true, now: Self.resetAt)
        #expect(line.text == "频限 90/100 请求 · 滚动 300 分钟 · 容量恢复已过期(最后成功快照)")
        #expect(!line.text.contains("重置"))
        #expect(line.help == nil)
    }

    @Test("非失败态即便时刻已过仍显绝对时间(等下次刷新,与主区口径一致)")
    func freshSnapshotPastRecoveryStillShowsTime() {
        let past = Self.resetAt.addingTimeInterval(-3_600)
        let line = RateLimitFactLine(window: rateLimitWindow(resetAt: past), fromFailedSnapshot: false, now: Self.resetAt)
        #expect(line.text == "频限 90/100 请求 · 滚动 300 分钟 · 容量恢复 \(Presentation.time(past))")
    }

    @Test("滚动跨度只取 label 括号段;无括号或空段为 nil")
    func rollingSpanParsing() {
        #expect(RateLimitFactLine.rollingSpan(fromLabel: "频限 · 滚动窗(300 分钟)") == "滚动 300 分钟")
        #expect(RateLimitFactLine.rollingSpan(fromLabel: "频限 · 滚动窗(2 小时)") == "滚动 2 小时")
        #expect(RateLimitFactLine.rollingSpan(fromLabel: "频限 · 滚动窗") == nil)
        #expect(RateLimitFactLine.rollingSpan(fromLabel: "周窗口") == nil)
    }

    // MARK: - 域码映射与胶囊 tooltip(P2-9)

    @Test("已知域码映射展示名;未知值原样透传")
    func domainDisplayName() {
        #expect(Presentation.domainDisplayName("DOMAIN_NEXUS") == "Nexus")
        #expect(Presentation.domainDisplayName("DOMAIN_UNKNOWN") == "DOMAIN_UNKNOWN")
    }

    @Test("胶囊 tooltip:已知域码「展示名(内部码)」,未知域码不重复")
    func planDomainHelpText() {
        #expect(Presentation.planDomainHelp("DOMAIN_NEXUS") == "服务域:Nexus(DOMAIN_NEXUS)")
        #expect(Presentation.planDomainHelp("DOMAIN_UNKNOWN") == "服务域:DOMAIN_UNKNOWN")
    }
}
