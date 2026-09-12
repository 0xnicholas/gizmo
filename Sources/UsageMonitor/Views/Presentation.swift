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

    // MARK: - 相对时间(骨架F+FC-1,#37):共享 formatter,分档可单测

    /// 重置倒计时:距 now <1h「约 N 分钟后重置」、<24h「约 N 小时后重置」(都向下取整);
    /// 跨天或已过期退回绝对「重置 MM-dd HH:mm」。失败态旧快照的「已过期」标注是
    /// 卡片层逻辑(需要 loadFailed 上下文),不在此测。
    static func resetCountdown(_ resetAt: Date, now: Date) -> String {
        let seconds = resetAt.timeIntervalSince(now)
        if seconds > 0, seconds < 3_600 {
            return "约 \(max(1, Int(seconds / 60))) 分钟后重置"
        }
        if seconds >= 3_600, seconds < 86_400 {
            return "约 \(Int(seconds / 3_600)) 小时后重置"
        }
        return absoluteReset(resetAt)
    }

    /// 倒计时形态的 tooltip/绝对档同形文案:分档遮住的精确时刻。
    static func absoluteReset(_ resetAt: Date) -> String {
        "重置 " + resetFormatter.string(from: resetAt)
    }

    /// 脚注「上次更新」:<1h「N 分钟前更新」(向下取整,最低 1);≥1h 或时钟倒漂退回绝对。
    static func updatedAgo(_ at: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(at)
        guard seconds >= 0, seconds < 3_600 else {
            return "上次更新 " + time(at)
        }
        return "\(max(1, Int(seconds / 60))) 分钟前更新"
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

/// 凭据状态行的收拢口径(骨架C,P1-5,#38):全部已配置且无读取失败时收成一行
/// 「三家凭据正常 · 管理」,把纵向空间还给总览与焦点卡;有任何问题(失效/未配置/
/// 读取失败)时只展开问题家。横幅管汇总、行管逐家入口的分工不由此处改变。
/// 加载失败但凭据已配置不算凭据问题(那归焦点卡与总览条口径)。
struct CredentialRowPresentation {
    /// 需要逐家展开的家,按展示序;凭据失效/未配置,或钥匙串读取失败(状态未知,
    /// 优先于凭据字段判定——读不到不等于正常)。
    let problemProviders: [Provider]

    /// 全绿收拢:无任何问题家。
    var isCollapsed: Bool { problemProviders.isEmpty }

    init(state: EngineState) {
        problemProviders = Provider.displayOrder.filter { provider in
            let runtime = state.provider(provider)
            return runtime.credential != .configured || state.credentialReadFailures.contains(provider)
        }
    }
}

/// 脚注刷新反馈口径(G,P2-1,#39):刷新中出「刷新中…」并保留「上次更新」
/// (屏上数据仍是上次的,不因刷新中抹掉);无任何成功刷新且不在刷新中才显
/// 「尚未刷新」;刷新完成 highlightDuration 内高亮「上次更新」文本。
/// 只消费刷新中状态,不动引擎刷新语义。
struct RefreshFooterPresentation {
    /// 完成高亮时长(秒):「点了没反应→数据到位」的确认窗口。
    static let highlightDuration: TimeInterval = 2

    /// 刷新中:「刷新中…」+ 轻 spinner。
    let showsRefreshingIndicator: Bool
    /// 从未成功刷新过且不在刷新中:占位「尚未刷新」。
    let showsNeverRefreshedPlaceholder: Bool
    /// 刚完成(高亮窗口内且当前不在刷新):「上次更新」文本高亮。
    let highlightsUpdatedText: Bool

    init(isRefreshing: Bool, hasUpdate: Bool, refreshFinishedAt: Date?, now: Date = Date()) {
        showsRefreshingIndicator = isRefreshing
        showsNeverRefreshedPlaceholder = !isRefreshing && !hasUpdate
        // 完成时刻在未来(时钟倒漂)不算刚完成,与相对时间分档的防御口径一致。
        highlightsUpdatedText = !isRefreshing && refreshFinishedAt.map { finished in
            finished <= now && now.timeIntervalSince(finished) < Self.highlightDuration
        } == true
    }
}

/// 每分钟刷新的时间性文本容器(骨架F+FC-1,#37):内部 TimelineView 仅挂载
/// (即 popover 可见)时运转,无全局定时器;重置倒计时/相对更新等时间性文案共用。
struct EveryMinute<Content: View>: View {
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(context.date)
        }
    }
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
