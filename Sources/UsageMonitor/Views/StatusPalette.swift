import Foundation
import UsageMonitorCore

/// 纯 sRGB 分量 + WCAG 亮度/对比度计算。无 SwiftUI 依赖,供调色板单测锚点与亮度阶梯。
struct StatusColorComponents: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// 8 比特 sRGB 分量(0–255)。
    init(r8: Int, g8: Int, b8: Int) {
        self.init(red: Double(r8) / 255, green: Double(g8) / 255, blue: Double(b8) / 255)
    }

    /// WCAG 相对亮度(0–1),https://www.w3.org/TR/WCAG21/#dfn-relative-luminance。
    var wcagLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 对比度(1–21),与顺序无关。
    func contrastRatio(against other: StatusColorComponents) -> Double {
        let l1 = wcagLuminance
        let l2 = other.wcagLuminance
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

/// 三态状态色的浅色加深变体(IC-1,#31):系统 `.green/.yellow/.red` 在浅色菜单栏下
/// 对比度仅 1.31/1.81/3.18(审计 #25 实测,基线 (238,238,238)),偏低态余光认不出。
/// 深色 appearance 维持系统色(对比度 6.56/8.70/3.51 全部合格),不设变体。
///
/// 锚点取审计实测:黄 (190,140,0)≈2.61、红 (206,52,38)≈4.37;绿锚点 (34,128,28)≈4.34
/// 与红几乎同亮度(0.159 vs 0.157),亮度阶梯「黄 > 红 > 绿」无法严格成立,故再加深一档
/// 到 (28,112,24)≈5.35——三态亮度 0.297 > 0.157 > 0.119 形成阶梯,红绿色弱下仍可分档。
enum StatusPalette {
    static let normal = StatusColorComponents(r8: 28, g8: 112, b8: 24)
    static let low = StatusColorComponents(r8: 190, g8: 140, b8: 0)
    static let critical = StatusColorComponents(r8: 206, g8: 52, b8: 38)

    /// 浅色 appearance 下的加深变体。
    static func lightVariant(for status: ProviderStatus) -> StatusColorComponents {
        switch status {
        case .normal: return normal
        case .low: return low
        case .critical: return critical
        }
    }
}
