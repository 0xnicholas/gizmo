import Foundation
import Testing
@testable import UsageMonitorCore

@Suite("百分比口径一致")
struct PercentTests {
    @Test("四舍五入,最低 1%,真 0 显示 0")
    func displayRules() {
        #expect(Percent.display(0.645) == 65)
        #expect(Percent.display(0.0004) == 1)   // 0.04% → 最低 1%
        #expect(Percent.display(0) == 0)
        #expect(Percent.display(-0.1) == 0)
        #expect(Percent.rounded(0.0004) == 0)   // 中性场景不钳制
    }

    @Test("图标数字与总览条「全局最紧」同源(用户故事 18)")
    func iconMatchesOverviewBar() {
        let evaluator = StatusEvaluator()
        let snapshots: [Provider: Snapshot] = [
            .glm: Fixture.snapshot(provider: .glm, windows: [
                Fixture.planWindow(limit: 10_000, remaining: 30, label: "5 小时窗"),
            ]),
        ]
        let overview = GlobalOverview.compute(snapshots: snapshots, evaluator: evaluator)
        let tightest = try! #require(overview.tightest)
        #expect(overview.iconPercent == tightest.displayPercent)
        #expect(tightest.displayPercent == 1)  // 0.3% → 图标与总览条都显示 1%
    }
}

@Suite("展示格式化")
struct MoneyFormatTests {
    @Test("额度数量带千位分隔符")
    func countGrouping() {
        #expect(Money.formatCount(15_929) == "15,929")
        #expect(Money.formatCount(12_000) == "12,000")
        #expect(Money.formatCount(7_500_000) == "7,500,000")
        #expect(Money.formatCount(0) == "0")
    }

    @Test("金额两位小数 + 币种符号")
    func moneyFormatting() {
        #expect(Money.format(Decimal(string: "62.4", locale: Locale(identifier: "en_US_POSIX"))!, currency: "CNY") == "¥62.40")
        #expect(Money.format(Decimal(3), currency: "USD") == "$3.00")
    }
}
