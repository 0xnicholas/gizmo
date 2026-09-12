import AppKit

/// MenuBarExtra 没有公开的「程序展开 popover」API;这里尽力找到它创建的
/// 菜单栏按钮并模拟一次点击(与用户手点等价)。
///
/// 找不到按钮(系统版本更迭、私有层级变化)时静默放弃,调用方保持
/// 「预设焦点,下次点开直达」的降级行为——绝不影响其余功能。
enum MenuBarExtraOpener {
    @MainActor
    static func openPopover() {
        for window in NSApp.windows {
            if let button = statusBarButton(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
    }

    /// 本 App 只有一个菜单栏项:任何窗口层级里遇到的第一个 NSStatusBarButton 就是它。
    private static func statusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusBarButton(in: subview) { return button }
        }
        return nil
    }
}
