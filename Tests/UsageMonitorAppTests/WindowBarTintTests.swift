import Foundation
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// 窗口行进度条的色档(FC-7,克制版,#40):中性灰为底,仅告警变色——
/// plan 窗按自身剩余档位(临界红、偏低黄,与 Thresholds 同档,「为什么这条黄了」
/// 不再心算);频限窗不参与 status 判定,恒中性。消灭同卡「蓝条 vs 绿点」两种好色。
@Suite("窗口行进度条色档(FC-7)")
struct WindowBarTintTests {
    @Test("plan 窗临界档(<0.10)红;边界 0.10 起转黄")
    func planCriticalIsRed() {
        #expect(WindowBarTint.of(kind: .planWindow, remainingFraction: 0.05) == .alertRed)
        #expect(WindowBarTint.of(kind: .planWindow, remainingFraction: 0.099) == .alertRed)
        #expect(WindowBarTint.of(kind: .planWindow, remainingFraction: 0.10) == .alertYellow)
    }

    @Test("plan 窗偏低档([0.10, 0.30))黄;0.30 起中性")
    func planLowIsYellow() {
        #expect(WindowBarTint.of(kind: .planWindow, remainingFraction: 0.29) == .alertYellow)
        #expect(WindowBarTint.of(kind: .planWindow, remainingFraction: 0.30) == .neutral)
    }

    @Test("plan 窗正常档中性(不再蓝/绿)")
    func planNormalIsNeutral() {
        #expect(WindowBarTint.of(kind: .planWindow, remainingFraction: 0.95) == .neutral)
        #expect(WindowBarTint.of(kind: .planWindow, remainingFraction: 1.0) == .neutral)
    }

    @Test("频限窗不参与 status 判定:任何档位恒中性")
    func rateLimitAlwaysNeutral() {
        #expect(WindowBarTint.of(kind: .rateLimit, remainingFraction: 0.05) == .neutral)
        #expect(WindowBarTint.of(kind: .rateLimit, remainingFraction: 0.95) == .neutral)
        #expect(WindowBarTint.of(kind: .rateLimit, remainingFraction: nil) == .neutral)
    }

    @Test("占比不可判定(limit 非正)中性")
    func unknownFractionNeutral() {
        #expect(WindowBarTint.of(kind: .planWindow, remainingFraction: nil) == .neutral)
    }

    @Test("色档消费 StatusEvaluator 判定(同源,不自行算阈值)")
    func consumesStatusEvaluator() {
        // 同一批分位上两套口径一一对应:bar 只做 status→色的映射,套档归 Core。
        let evaluator = StatusEvaluator()
        for fraction in [0.05, 0.099, 0.10, 0.29, 0.30, 0.95] {
            let tint = WindowBarTint.of(kind: .planWindow, remainingFraction: fraction)
            switch evaluator.status(forRemainingFraction: fraction) {
            case .critical: #expect(tint == .alertRed)
            case .low: #expect(tint == .alertYellow)
            case .normal: #expect(tint == .neutral)
            }
        }
    }
}
