import SwiftUI
import UsageMonitorCore

/// 展示层的映射:消费引擎的 status / 快照,不自行计算阈值。
enum Presentation {
    static func color(for status: ProviderStatus?) -> Color {
        switch status {
        case .normal: return .green
        case .low: return .yellow
        case .critical: return .red
        case nil: return .secondary
        }
    }

    static func label(for status: ProviderStatus) -> String {
        switch status {
        case .normal: return "正常"
        case .low: return "偏低"
        case .critical: return "临界"
        }
    }

    static func symbol(for status: ProviderStatus?) -> String {
        switch status {
        case .critical: return "!"
        case .normal, .low: return "✓"
        case nil: return "—"
        }
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func resetText(_ date: Date?) -> String? {
        guard let date else { return nil }
        return "重置 " + resetFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}

/// 菜单栏图标口径:数字 = 全局最低 plan-window 剩余%(四舍五入整数,最低 1%),
/// 颜色 = 全局最差 status(含 DeepSeek 余额档位);无任何窗口数据时灰「—」。
struct MenuBarPresentation {
    let text: String
    let color: Color

    init(state: EngineState) {
        if let percent = state.overview.iconPercent {
            text = "\(percent)%"
            color = Presentation.color(for: state.overview.worstStatus ?? .normal)
        } else {
            text = "—"
            color = Presentation.color(for: nil)
        }
    }
}
