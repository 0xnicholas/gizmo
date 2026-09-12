import Foundation
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// 脚注刷新反馈口径(G,P2-1,#39):刷新中出「刷新中…」并保留「上次更新」
/// (屏上数据仍是上次的,不因刷新中抹掉);无任何成功刷新且不在刷新中才显
/// 「尚未刷新」;刷新完成 highlightDuration 内高亮「上次更新」文本。
/// 只消费刷新中状态,不动引擎刷新语义。
@Suite("脚注刷新反馈(G)")
struct RefreshFooterPresentationTests {
    private static let now = Date(timeIntervalSince1970: 1_789_000_000)

    private func presentation(
        isRefreshing: Bool = false,
        hasUpdate: Bool = true,
        finishedAt: Date? = nil,
        now: Date = RefreshFooterPresentationTests.now
    ) -> RefreshFooterPresentation {
        RefreshFooterPresentation(
            isRefreshing: isRefreshing,
            hasUpdate: hasUpdate,
            refreshFinishedAt: finishedAt,
            now: now
        )
    }

    // MARK: 刷新中指示

    @Test("刷新中:出「刷新中…」,不出「尚未刷新」,不高亮")
    func refreshingShowsIndicator() {
        let p = presentation(isRefreshing: true)
        #expect(p.showsRefreshingIndicator)
        #expect(!p.showsNeverRefreshedPlaceholder)
        #expect(!p.highlightsUpdatedText)
    }

    @Test("刷新中且从未成功过:也出「刷新中…」,不出「尚未刷新」")
    func refreshingWithoutUpdateStillShowsIndicator() {
        let p = presentation(isRefreshing: true, hasUpdate: false)
        #expect(p.showsRefreshingIndicator)
        #expect(!p.showsNeverRefreshedPlaceholder)
    }

    @Test("不在刷新且无任何成功刷新:「尚未刷新」")
    func idleWithoutUpdateShowsPlaceholder() {
        let p = presentation(isRefreshing: false, hasUpdate: false)
        #expect(!p.showsRefreshingIndicator)
        #expect(p.showsNeverRefreshedPlaceholder)
    }

    @Test("不在刷新且有更新:无指示无占位(正常脚注)")
    func idleWithUpdateIsPlain() {
        let p = presentation(isRefreshing: false, hasUpdate: true)
        #expect(!p.showsRefreshingIndicator)
        #expect(!p.showsNeverRefreshedPlaceholder)
    }

    // MARK: 完成高亮

    @Test("完成 1 秒内:高亮「上次更新」")
    func justFinishedHighlights() {
        let p = presentation(finishedAt: Self.now.addingTimeInterval(-1))
        #expect(p.highlightsUpdatedText)
    }

    @Test("完成整 2 秒不高亮(窗口为开区间);3 秒更不高亮")
    func highlightWindowBoundary() {
        #expect(!presentation(finishedAt: Self.now.addingTimeInterval(-2)).highlightsUpdatedText)
        #expect(!presentation(finishedAt: Self.now.addingTimeInterval(-3)).highlightsUpdatedText)
    }

    @Test("未见完成(刚打开 popover):不高亮")
    func noCompletionNoHighlight() {
        #expect(!presentation(finishedAt: nil).highlightsUpdatedText)
    }

    @Test("完成后又立刻开始新刷新:刷新中不高亮(指示优先)")
    func newRefreshSuppressesHighlight() {
        let p = presentation(isRefreshing: true, finishedAt: Self.now.addingTimeInterval(-1))
        #expect(p.showsRefreshingIndicator)
        #expect(!p.highlightsUpdatedText)
    }

    @Test("完成时刻在未来(时钟倒漂):不高亮")
    func futureCompletionNotHighlighted() {
        #expect(!presentation(finishedAt: Self.now.addingTimeInterval(5)).highlightsUpdatedText)
    }
}
