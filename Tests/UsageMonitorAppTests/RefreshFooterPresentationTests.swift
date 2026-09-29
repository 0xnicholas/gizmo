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

/// 刷新节奏文案(#60):脚注与 tooltip 里的分钟数/轮数由当前 `Thresholds` 算出,不再写死——
/// 这几个数字此前分散写死在文案与阈值里,改周期得记得同步三处。
@Suite("刷新节奏文案(#60)")
struct RefreshCadenceCopyTests {
    @Test("默认:数字与阈值同源(周期 20 分钟 / 3 轮 ≈ 60 分钟)")
    func defaultsFollowThresholds() {
        #expect(RefreshCadenceCopy.footer() == "自动刷新 20 分钟")
        #expect(
            RefreshCadenceCopy.help()
                == "每 20 分钟后台轮询三家;单家连续失败 3 轮(≈60 分钟)显示加载失败;打开本面板与手动刷新即时生效。"
        )
    }

    @Test("换一份 Thresholds:周期、轮数与「轮数 × 周期」三处都跟着算")
    func followsInjectedThresholds() {
        let thresholds = Thresholds(failureRoundsBeforeLoadFailure: 2, refreshInterval: 45 * 60)
        #expect(RefreshCadenceCopy.footer(thresholds: thresholds) == "自动刷新 45 分钟")
        #expect(
            RefreshCadenceCopy.help(thresholds: thresholds)
                == "每 45 分钟后台轮询三家;单家连续失败 2 轮(≈90 分钟)显示加载失败;打开本面板与手动刷新即时生效。"
        )
    }

    @Test("单位规则:一律 N 分钟——满 60 不进小时;四舍五入;下限 1 分钟")
    func minutesNeverEntersHours() {
        #expect(RefreshCadenceCopy.minutes(20 * 60) == "20 分钟")
        #expect(RefreshCadenceCopy.minutes(60 * 60) == "60 分钟")
        #expect(RefreshCadenceCopy.minutes(90 * 60) == "90 分钟")
        #expect(RefreshCadenceCopy.minutes(90) == "2 分钟")  // 1.5 → 四舍五入
        #expect(RefreshCadenceCopy.minutes(89) == "1 分钟")
        #expect(RefreshCadenceCopy.minutes(5) == "1 分钟")  // 注入极短周期也不输出「0 分钟」
    }
}
