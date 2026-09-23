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

    /// 紧凑显示名(tab、a11y 等空间受限/VoiceOver 朗读场景):GLM / Kimi / DeepSeek。
    static func shortName(_ provider: Provider) -> String {
        switch provider {
        case .glm: return "GLM"
        case .kimi: return "Kimi"
        case .deepseek: return "DeepSeek"
        }
    }

    /// 「点名某状态家」的共享口径:持快照、凭据正常、且**未到期**(失效家的旧档
    /// 是凭据问题归横幅;到期家的档是死数据,#56 退出全局结论)。总览条 alertLine
    /// 与标题/副行的口径参考共用,防两处漂移。
    static func providers(withStatus status: ProviderStatus, in state: EngineState) -> [Provider] {
        Provider.displayOrder.filter { provider in
            let runtime = state.provider(provider)
            return runtime.hasSnapshot && runtime.credential == .configured && runtime.status == status
                && !state.overview.expiredProviders.contains(provider)
        }
    }

    /// 「点名到期家」的共享口径(#56):与 `providers(withStatus:)` 同型的**点名口径**
    /// ——与引擎侧 `state.overview.expiredProviders`(枚举序、不看凭据)是两个东西:
    /// 这里按展示序、且只点名凭据正常的持快照到期家(凭据问题优先于到期,归横幅)。
    /// 总览条「已到期:」行、全到期判定共用(#59 起图标 a11y 不再报全局到期:
    /// 图标恒为 Kimi,到期与否只看 Kimi 自己)。
    static func namedExpiredProviders(in state: EngineState) -> [Provider] {
        Provider.displayOrder.filter { provider in
            state.overview.expiredProviders.contains(provider)
                && state.provider(provider).credential == .configured
        }
    }

    /// 三家全到期(#56):总览条「全局最紧」已无参评家——标题换「三家套餐均已到期」,
    /// 免得「—」产生「是不是没联网」的歧义。手动标记入口只给 Kimi(#58)、
    /// DeepSeek 恒 unknown:此态仍不可自然达到(预览/测试可注入 planStates 构造)。
    static func isAllPlansExpired(in state: EngineState) -> Bool {
        namedExpiredProviders(in: state).count == Provider.allCases.count
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

    /// 次级频限行的 tooltip:带日期的完整恢复时刻(行内只显 HH:mm,跨天时消歧;
    /// 不用「重置」措辞,与频限区口径一致)。
    static func recoveryMoment(_ resetAt: Date) -> String {
        "容量恢复 " + resetFormatter.string(from: resetAt)
    }

    /// 脚注「上次更新」:<1h「N 分钟前更新」(向下取整,最低 1);≥1h 或时钟倒漂退回绝对。
    static func updatedAgo(_ at: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(at)
        guard seconds >= 0, seconds < 3_600 else {
            return "上次更新 " + time(at)
        }
        return "\(max(1, Int(seconds / 60))) 分钟前更新"
    }

    // MARK: - 套餐有效期(#53)

    /// 有效期行末端的展示口径:MM-dd,按北京时间(+08:00)。
    /// 有效期串本身按 +08:00 解析(见 `GLMParser.periodBounds`),展示若随系统时区走,
    /// 跨时区机器上「有效期至」会差一天。
    static func validityDate(_ validUntil: Date) -> String {
        validityFormatter.string(from: validUntil)
    }

    // MARK: - 到期态(#54)

    /// 到期档文案:卡头状态位与 tab 速览共用同一常量,两处不打架。
    static let planExpiredLabel = "已到期"

    /// 手动标记的归属(#58):「手动标记于 MM-dd」。系统时区、到日——这是「你何时标的」,
    /// 不是 provider 的有效期钟(后者按北京时间,见 `validityDate`);与 `observedAt`
    /// 归属同一取向。
    static func manualExpiryAttribution(_ markedAt: Date) -> String {
        "手动标记于 " + markedFormatter.string(from: markedAt)
    }

    /// 手动标记控件的两态标题(#58):卡上 actions 行与设置窗口同款,文案只此一份。
    static func manualExpiryActionTitle(marked: Bool) -> String {
        marked ? "已续订?恢复显示" : "标记为已到期"
    }

    /// 「(剩 N 天)」:有效期剩余 ≤ 提醒天数时补在「有效期至」行末。已到期或剩余超窗
    /// → nil——后缀只服务「即将到期」的**文本**,没有界面态,不引入第四种状态色。
    /// 窗判定与天数口径都取自 Core(`PlanExpiryNotice.isApproaching` / `remainingDays`):
    /// 卡上行后缀与 #57 的到期通知文案是同一句话的两处落点,公式只此一份。
    static func expiringSoonSuffix(validUntil: Date, now: Date, reminderDays: Int) -> String? {
        guard PlanExpiryNotice.isApproaching(validUntil: validUntil, now: now, reminderDays: reminderDays) else {
            return nil
        }
        return "(剩 \(PlanExpiryNotice.remainingDays(until: validUntil, now: now)) 天)"
    }

    /// 到期结论的陈旧归属:「(有效期数据来自 MM-dd HH:mm)」。观测时刻距 now 超过阈值
    /// (默认 2× 轮询周期,`Thresholds.expiryStalenessThreshold`)时附上——陈旧是展示属性,
    /// 不是第四态;恰好等于阈值、或时钟倒漂(观测时刻在未来)都不算。
    static func staleValidityAttribution(observedAt: Date, now: Date, threshold: TimeInterval) -> String? {
        guard now.timeIntervalSince(observedAt) > threshold else { return nil }
        return "(有效期数据来自 \(observedMoment(observedAt)))"
    }

    /// 观测时刻的展示口径:MM-dd HH:mm,随系统时区——那是「我们何时取到数据」,
    /// 不是 provider 的有效期钟(后者才按北京时间,见 `validityDate`)。
    static func observedMoment(_ date: Date) -> String {
        resetFormatter.string(from: date)
    }

    // MARK: - 域码展示名(P2-9,FC-6)

    /// 已知内部域码 → 展示名;未知值原样透传(展示层映射,不动解析层)。
    static func domainDisplayName(_ raw: String) -> String {
        switch raw {
        case "DOMAIN_NEXUS": return "Nexus"
        default: return raw
        }
    }

    /// 胶囊 tooltip:服务域展示名 + 括注内部码(排查时对得上后端字段);
    /// 未知域码不重复自身。
    static func planDomainHelp(_ domain: String) -> String {
        let name = domainDisplayName(domain)
        return name == domain ? "服务域:\(domain)" : "服务域:\(name)(\(domain))"
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

    /// 套餐有效期专用:时区口径取自 Core 的 `PlanValidity.timeZone`(北京时间 +08:00,不随系统时区漂移)。
    private static let validityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = PlanValidity.timeZone
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    /// 手动标记日期的归属专用(#58):系统时区(「你何时标的」随本机钟),只到日。
    private static let markedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "MM-dd"
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

/// 频限次级单行(P2-6,FC-3):「频限 90/100 请求 · 滚动 300 分钟 · 容量恢复 08:56」——
/// 不带进度条、不沿用「重置」一词(滚动窗是容量随时间滑出恢复,不是额度重置);
/// 滚动跨度取自解析层 label「频限 · 滚动窗(300 分钟)」的括号段,缺失时省略。
/// 失败态快照的恢复时刻已过时降级标注(与主区 resetLine 同语义,不假装有效)。
struct RateLimitFactLine {
    let text: String
    /// tooltip:带日期的完整恢复时刻(行内只显 HH:mm,跨天时靠 tooltip 消歧);
    /// 无 resetAt 或已降级标注时 nil。
    let help: String?

    init(window: QuotaWindow, fromFailedSnapshot: Bool = false, now: Date = Date()) {
        var parts = ["频限 \(Money.formatCount(window.remaining))/\(Money.formatCount(window.limit)) \(window.unit)"]
        if let span = Self.rollingSpan(fromLabel: window.label) {
            parts.append(span)
        }
        if let resetAt = window.resetAt {
            if fromFailedSnapshot, resetAt <= now {
                parts.append("容量恢复已过期(最后成功快照)")
                help = nil
            } else {
                parts.append("容量恢复 " + Presentation.time(resetAt))
                help = Presentation.recoveryMoment(resetAt)
            }
        } else {
            help = nil
        }
        text = parts.joined(separator: " · ")
    }

    /// label「频限 · 滚动窗(300 分钟)」→「滚动 300 分钟」;无括号段 → nil。
    static func rollingSpan(fromLabel label: String) -> String? {
        guard let open = label.firstIndex(of: "("),
              let close = label.lastIndex(of: ")"),
              open < close
        else { return nil }
        return "滚动 " + label[label.index(after: open)..<close]
    }
}

/// 窗口行进度条的色档(FC-7,克制版,#40):中性灰为底,仅告警变色——plan 窗色档
/// 直接消费 StatusEvaluator 的临界/偏低判定(同一规则,「为什么这条黄了」不再
/// 心算);频限窗不参与 status 判定,恒中性。消灭同卡「蓝条 vs 绿点」两种好色。
enum WindowBarTint {
    case alertRed
    case alertYellow
    case neutral

    static func of(kind: QuotaWindow.Kind, remainingFraction: Double?) -> WindowBarTint {
        guard kind == .planWindow, let fraction = remainingFraction else { return .neutral }
        switch StatusEvaluator().status(forRemainingFraction: fraction) {
        case .critical: return .alertRed
        case .low: return .alertYellow
        case .normal: return .neutral
        }
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

/// 单家 tab 的速览数字口径(P2-5,B,#43):tab 文本追加各家 plan-window 最低
/// 剩余%——数字与焦点卡窗口行、总览大数字同源(Percent.display,经
/// `Snapshot.tightestPlanWindow`,频限窗不参与),不用切两次标签页
/// 看另外两家。颜色随该家 status,口径乙同型:窗口家色档 = 最紧窗自身色档;
/// DeepSeek 无窗的「彩色 —」由余额色档给色;无快照家灰「—」。
/// tab 圆点与数字共用同一取色档(quickFigure.colorStatus),两处不打架。
/// 到期家(#54)速览位换「已到期」灰显——不给已失效的百分比留位置;
/// 凭据问题优先于到期(失效家不做到期断言)。
struct TabPercentPresentation {
    let text: String
    /// 数字口径的取色档:持快照 = 该家 status;无快照或到期 = nil(灰)。
    let colorStatus: ProviderStatus?

    init(runtime: ProviderRuntimeState, now: Date = Date()) {
        // 到期(#54):凭据问题优先于到期——失效家不做到期断言;到期家速览位换
        // 「已到期」灰显,不给已失效的百分比留位置。手动态(#58)同属到期,同一入口。
        let plan = PlanState.evaluate(runtime: runtime, now: now)
        if runtime.credential == .configured, plan.isExpired {
            text = Presentation.planExpiredLabel
            colorStatus = nil
            return
        }
        colorStatus = runtime.hasSnapshot ? runtime.status : nil
        if let fraction = runtime.snapshot?.tightestPlanWindow?.remainingFraction {
            text = "\(Percent.display(fraction))%"
        } else {
            text = "—"
        }
    }
}

/// popover 总览条「全局最紧」的呈现口径:数字 = 全局最低 plan-window 剩余%
/// (四舍五入整数,最低 1%),颜色随数字口径(口径乙,IC-4+IC-5):有窗 = 最紧窗
/// 所属 provider 的档位,无窗但持快照 = 该家档位给色的「彩色 —」,全无快照 = 灰「—」。
/// 全局最差(含 DeepSeek 余额档)仍由总览条圆点/alertLine 与临界通知兜底。
///
/// 菜单栏图标**不再**消费此处(#59):图标恒为 Kimi 一家,见
/// `MenuBarPercentPresentation`;两处数字仍共用 `Percent.display` 与
/// `Snapshot.tightestPlanWindow`,除法与取整口径不分叉。
struct GlobalPercentPresentation {
    let text: String
    let color: Color
    /// 数字口径的取色档(口径乙,IC-4+IC-5,#41):颜色随数字——有窗 = 最紧窗
    /// 所属 provider 的 status(即最紧窗自身档位);无任何窗口 = 持快照家的档位
    /// (现实里 = DeepSeek 余额/可用性档,「彩色 —」);全无快照 = nil(灰)。
    /// DeepSeek 余额临界不再把数字拉红,由临界通知与总览条(圆点/alertLine
    /// 仍消费 worstStatus)兜底——「红 65%」混叠形态消灭。
    let colorStatus: ProviderStatus?

    init(state: EngineState, scheme: ColorScheme) {
        if let percent = state.overview.tightestPercent, let tightest = state.overview.tightest {
            text = "\(percent)%"
            colorStatus = state.provider(tightest.provider).status
        } else {
            text = "—"
            colorStatus = Self.snapshotHolderStatus(state)
        }
        color = Presentation.color(for: colorStatus, scheme: scheme)
    }

    /// 无任何 plan-window 时:有快照的家按自身档位给色(DeepSeek-only 的余额档
    /// 「彩色 —」);全无快照则灰(全新安装口径不变)。按展示序取第一个持快照家,
    /// 现实里无窗持快照的只有 DeepSeek。到期家(#56)被跳过——死档不给「—」夸活;
    /// 全部持快照家都到期时退灰(未到期家一个不剩,没有谁能给「—」上色)。
    private static func snapshotHolderStatus(_ state: EngineState) -> ProviderStatus? {
        for provider in Provider.displayOrder {
            guard !state.overview.expiredProviders.contains(provider) else { continue }
            let runtime = state.provider(provider)
            if runtime.hasSnapshot { return runtime.status }
        }
        return nil
    }
}

/// 菜单栏图标的陈旧判定(IC-3):图标本体与一行说明共用一处——看得见的降透明度
/// 与听得见的「数据较旧(最后成功 HH:mm)」必须是同一个判定,否则两个通道会各说各话。
enum MenuBarStaleness {
    /// 陈旧阈值:2× 轮询间隔(默认 30 分钟 → 60 分钟)。展示参数,不动引擎(IC-3,spec P0-3)。
    static let threshold: TimeInterval = 2 * Thresholds().refreshInterval

    /// 按 **Kimi 自己**的 lastSuccessAt 判定——不用全局 lastUpdatedAt,那会被别家成功
    /// 刷新冲掉,不能反映「这个数字」的新旧;lastSuccessAt 未知时不误标。
    ///
    /// 与 `loadFailed` **正交**(IC-3 原口径):陈旧看的是数据的**年龄**(2× 轮询间隔),
    /// 加载失败看的是**刷新**这几次没成——刚失败时数据可能只旧几分钟,此时降透明度
    /// 是撒谎。手动连点刷新只几十秒就能凑满 3 轮失败,不是纸上空谈;
    /// 两个事实在一行说明里各占半句(a11y 侧)。
    static func isStale(_ runtime: ProviderRuntimeState, now: Date) -> Bool {
        runtime.lastSuccessAt.map { now.timeIntervalSince($0) > threshold } ?? false
    }
}

/// 菜单栏图标口径(#59):图标恒为 **Kimi 一家**的用量,不再随「全局最紧」换人。
/// 数字 = Kimi 最紧 plan-window 的剩余%(经 `Snapshot.tightestPlanWindow`,与 Kimi 焦点卡
/// 窗口行 / tab 速览同源),颜色随数字 = Kimi 自身 status——他者更紧(含 DeepSeek
/// 余额档)不改图标上场家。popover 总览条仍按口径乙给「彩色 —」
/// (spec `2026-ux-improvements` P2-3 的图标半句由本口径修订:菜单栏不再有
/// 「谁最紧显示谁」与 DeepSeek-only 彩色「—」形态;总览条半句不变)。
///
/// 没有数字的来历一律灰「—」,由 `MenuBarAccessibilityPresentation` 讲清:
/// 凭据问题(未配置 / 失效 / 读取失败)、到期(#54 自动 / #58 手动)、
/// 加载失败尚无成功、快照无套餐窗。
struct MenuBarPercentPresentation {
    let text: String
    let color: Color
    /// 数字口径的取色档:持数字 = Kimi 自身 status;无数字 = nil(灰)。
    let colorStatus: ProviderStatus?
    /// 数字是否陈旧(`MenuBarStaleness`,与 a11y 的陈旧半句同一判定)。
    let isStale: Bool

    init(state: EngineState, scheme: ColorScheme, now: Date = Date()) {
        let runtime = state.provider(.kimi)
        // 凭据问题优先于到期(全库同序):失效家的旧档是凭据问题,不是「现在还能用多少」。
        // 图标不给冻结数字假装新鲜的机会——「已配置」是数字上场的第一道门。
        if runtime.credential != .configured {
            text = "—"
            colorStatus = nil
            isStale = false
        } else if PlanState.evaluate(runtime: runtime, now: now).isExpired {
            // 到期(#54/#58,含手动标记):死档不给数字留位置(与 tab 速览同位)。
            text = "—"
            colorStatus = nil
            isStale = false
        } else if let fraction = runtime.snapshot?.tightestPlanWindow?.remainingFraction {
            text = "\(Percent.display(fraction))%"
            colorStatus = runtime.status
            isStale = MenuBarStaleness.isStale(runtime, now: now)
        } else {
            // 加载失败尚无成功 / 快照无套餐窗:同形灰「—」,来历归 a11y。
            text = "—"
            colorStatus = nil
            isStale = false
        }
        color = Presentation.color(for: colorStatus, scheme: scheme)
    }
}

/// 菜单栏图标 a11y 一行说明(IC-2,P2-7,#45 的 Kimi 口径,#59):
/// 「Kimi 周窗口剩余 66%,状态正常」——VoiceOver 看不见颜色,也不该只听到一个
/// 光秃的「—」:数字口径(哪窗多少 + 哪档)、数据是否陈旧(降透明度是说给眼睛的,
/// 读屏得听到同一事实)与「—」的来历(未配置 / 凭据失效 / 读取失败 / 到期 /
/// 加载失败 / 尚无数据)都在这一行里讲清。
/// 凭据问题排在最前:读取失败是状态未知,不误报「未配置」;失效家的到期
/// 断言不做(与焦点卡/tab 同序)。
struct MenuBarAccessibilityPresentation {
    let text: String

    init(state: EngineState, now: Date = Date()) {
        let runtime = state.provider(.kimi)
        let name = Presentation.shortName(.kimi)
        if state.credentialReadFailures.contains(.kimi) {
            text = "用量监视器,\(name) 凭据状态未知(钥匙串读取失败)"
            return
        }
        switch runtime.credential {
        case .missing:
            text = "用量监视器,\(name) 尚未配置凭据"
            return
        case .invalid:
            text = "用量监视器,\(name) 凭据失效,请在设置中重新配置"
            return
        case .configured:
            break
        }
        switch PlanState.evaluate(runtime: runtime, now: now) {
        case .manuallyExpired:
            text = "用量监视器,\(name) 套餐已到期(手动标记)"
            return
        case .expired:
            text = "用量监视器,\(name) 套餐已到期"
            return
        case .active, .unknown:
            break
        }
        guard let window = runtime.snapshot?.tightestPlanWindow,
              let fraction = window.remainingFraction
        else {
            // 「—」的三种来历分开讲:加载失败(连旧数据都没有) / 只持非套餐窗 /
            // 尚未刷过。都不留「是不是没联网」的歧义。
            if runtime.loadFailed {
                text = "用量监视器,\(name) 加载失败,尚无数据"
            } else if runtime.hasSnapshot {
                text = "用量监视器,\(name) 暂无套餐窗口数据"
            } else {
                text = "用量监视器,\(name) 尚无数据"
            }
            return
        }
        let windowName = window.label.isEmpty ? "\(name) 套餐窗口" : "\(name) \(window.label)"
        var parts = [
            "\(windowName)剩余 \(Percent.display(fraction))%",
            "状态\(Presentation.label(for: runtime.status))",
        ]
        if runtime.loadFailed {
            // IC-3:数字来自最后一次成功——旧数字附「最后成功 HH:mm」,与焦点卡/总览条同口径。
            parts.append(runtime.lastSuccessAt.map { "加载失败(最后成功 \(Presentation.time($0)))" } ?? "加载失败")
        }
        // 陈旧只有**视觉**表达(数字降透明度),读屏用户拿不到——同一事实在这里
        // 说一遍;时刻已由「加载失败」半句给出时不重复(两个事实各占半句)。
        if let lastSuccessAt = runtime.lastSuccessAt, MenuBarStaleness.isStale(runtime, now: now) {
            parts.append(runtime.loadFailed
                ? "数据较旧"
                : "数据较旧(最后成功 \(Presentation.time(lastSuccessAt)))")
        }
        text = parts.joined(separator: ",")
    }
}
