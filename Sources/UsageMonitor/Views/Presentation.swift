import SwiftUI
import UsageMonitorCore

/// 展示层的映射:消费引擎的 status / 快照,不自行计算阈值。
enum Presentation {
    /// 三态状态色,外观感知:浅色用 `StatusPalette` 加深变体(IC-1,#31),深色维持系统色;
    /// 无数据用 secondary。popover / 焦点卡同一调色板。
    static func color(for status: ProviderStatus?, scheme: ColorScheme) -> Color {
        guard let status else { return .secondary }
        if scheme == .light {
            return color(from: StatusPalette.lightVariant(for: status))
        }
        return systemColor(for: status)
    }

    private static func color(from components: StatusColorComponents) -> Color {
        Color(red: components.red, green: components.green, blue: components.blue)
    }

    private static func systemColor(for status: ProviderStatus) -> Color {
        switch status {
        case .normal: return .green
        case .low: return .yellow
        case .critical: return .red
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

/// 全局结论数字的呈现口径:数字 = 全局最低 plan-window 剩余%(四舍五入整数,最低 1%),
/// 颜色 = 全局最差 status(含 DeepSeek 余额档位);无任何窗口数据时灰「—」。
/// 菜单栏图标与 popover 总览条共用同一映射,两处数字与颜色不打架(用户故事 18)。
struct GlobalPercentPresentation {
    /// 陈旧阈值:2× 轮询间隔(默认 30 分钟 → 60 分钟)。展示参数,不动引擎(IC-3,spec P0-3)。
    static let staleThreshold: TimeInterval = 2 * Thresholds().refreshInterval

    let text: String
    let color: Color
    /// 数字是否陈旧:最紧窗所属 provider 自己的 lastSuccessAt 距 now 超阈值——
    /// 不用全局 lastUpdatedAt,那会被别家成功刷新冲掉,不能反映「这个数字」的新旧。
    let isStale: Bool

    init(state: EngineState, scheme: ColorScheme, now: Date = Date()) {
        if let percent = state.overview.iconPercent, let tightest = state.overview.tightest {
            text = "\(percent)%"
            color = Presentation.color(for: state.overview.worstStatus ?? .normal, scheme: scheme)
            isStale = state.provider(tightest.provider).lastSuccessAt
                .map { now.timeIntervalSince($0) > Self.staleThreshold }
                ?? false
        } else {
            text = "—"
            color = Presentation.color(for: nil, scheme: scheme)
            isStale = false
        }
    }
}
