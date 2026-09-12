import Testing
import UserNotifications
@testable import UsageMonitor

/// 通知同屏不打扰(C4,#42 / P2-4):popover 或设置窗口正可见时,临界/失效通知
/// 不横幅、不响(仍进通知中心);不可见时行为不变(横幅 + 声音)。
/// 决策是纯逻辑(UNNotification 无法在单测构造,willPresent 不可直测),
/// 以静态决策函数为缝,由 NotificationPresenter.willPresent 消费。
@Suite("通知同屏不打扰(C4)呈现决策")
struct NotificationPresentationTests {
    @Test("任一呈现面可见即抑制:popover、设置窗口四组合", arguments: [
        (false, false, false),
        (true, false, true),
        (false, true, true),
        (true, true, true),
    ])
    func suppressionRequiresAnySurface(
        popoverVisible: Bool, settingsVisible: Bool, expected: Bool
    ) {
        #expect(
            NotificationPresentationDecision.isSuppressed(
                popoverVisible: popoverVisible,
                settingsVisible: settingsVisible
            ) == expected
        )
    }

    @Test("抑制:空 options——不横幅、不响(通知仍投递进通知中心)")
    func suppressedDeliversSilently() {
        #expect(NotificationPresentationDecision.options(suppress: true).isEmpty)
    }

    @Test("不抑制:横幅 + 声音(与原有行为一致)")
    func notSuppressedBannersWithSound() {
        let options = NotificationPresentationDecision.options(suppress: false)
        #expect(options.contains(.banner))
        #expect(options.contains(.sound))
    }
}
