import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// 三态色浅色加深变体(IC-1,#31):浅色菜单栏下黄 1.31 / 绿 1.81 / 红 3.18 的对比度不足,
/// 改用加深变体;深色 appearance 维持系统色(不在此测,由 render-previews 像素取样验收)。
/// 对比度基线取菜单栏图标审计(#25)实测的浅色栏 ≈ (238,238,238)。
@Suite("三态色浅色加深变体(IC-1)")
struct StatusPaletteTests {
    /// 审计实测的浅色菜单栏背景基线。
    private static let lightMenuBar = StatusColorComponents(r8: 238, g8: 238, b8: 238)

    @Test("浅色三态对比度:黄 ≥2.5、绿 ≥4.2、红 ≥4.2(现状 1.31/1.81/3.18)")
    func lightContrastMeetsThresholds() {
        #expect(StatusPalette.lightVariant(for: .low).contrastRatio(against: Self.lightMenuBar) >= 2.5)
        #expect(StatusPalette.lightVariant(for: .normal).contrastRatio(against: Self.lightMenuBar) >= 4.2)
        #expect(StatusPalette.lightVariant(for: .critical).contrastRatio(against: Self.lightMenuBar) >= 4.2)
    }

    @Test("浅色亮度阶梯:黄 > 红 > 绿(红绿色弱下仍可分档)")
    func lightLuminanceLadder() {
        let yellow = StatusPalette.lightVariant(for: .low).wcagLuminance
        let red = StatusPalette.lightVariant(for: .critical).wcagLuminance
        let green = StatusPalette.lightVariant(for: .normal).wcagLuminance
        #expect(yellow > red, "黄应最亮:yellow=\(yellow) red=\(red)")
        #expect(red > green, "红应居中、绿最深:red=\(red) green=\(green)")
    }

    @Test("审计锚点复核:黄 (190,140,0)≈2.61、红 (206,52,38)≈4.37(校验计算口径与审计一致)")
    func wcagMathMatchesAuditAnchors() {
        let yellowAnchor = StatusColorComponents(r8: 190, g8: 140, b8: 0)
        let redAnchor = StatusColorComponents(r8: 206, g8: 52, b8: 38)
        #expect(abs(yellowAnchor.contrastRatio(against: Self.lightMenuBar) - 2.61) < 0.02)
        #expect(abs(redAnchor.contrastRatio(against: Self.lightMenuBar) - 4.37) < 0.02)
    }

    /// #51 提亮决议:绿从额外加深档 (28,112,24)≈5.35 回到阶梯内最高档——
    /// L 压红锚之下保住阶梯,对比度仍 ≥4.2。锚点锁定防无声漂回。
    @Test("绿锚点锁定:(30,126,34)≈4.46,亮度压红锚之下(#51 提亮决议)")
    func greenAnchorLocked() {
        let green = StatusPalette.lightVariant(for: .normal)
        #expect(green == StatusColorComponents(r8: 30, g8: 126, b8: 34))
        #expect(abs(green.contrastRatio(against: Self.lightMenuBar) - 4.46) < 0.02)
        #expect(green.wcagLuminance < StatusPalette.lightVariant(for: .critical).wcagLuminance)
    }

    @Test("纯黑对纯白对比度 = 21(WCAG 口径自检)")
    func extremeContrastIs21() {
        let black = StatusColorComponents(r8: 0, g8: 0, b8: 0)
        let white = StatusColorComponents(r8: 255, g8: 255, b8: 255)
        #expect(abs(black.contrastRatio(against: white) - 21) < 1e-6)
    }
}
