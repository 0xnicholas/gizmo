import SwiftUI
import UsageMonitorCore

/// 焦点卡片:按数据模型只渲染存在的字段;错误/失效/缺失有各自的占位形态。
struct FocusCardView: View {
    let provider: Provider
    let runtime: ProviderRuntimeState
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // 一次渲染只取一次 now(#54):planState 是时间性求值,头部/归属/有效期行
        // 共用同一时刻,不在同一次 body 里跨过到期边界。
        let now = Date()
        let plan = PlanState.evaluate(runtime: runtime, now: now)
        // 到期形态的成立:凭据问题优先于到期——失效家回到既有凭据占位,不做到期断言。
        let expired = runtime.credential == .configured && plan.isExpired
        // 手动态(#58):用户声明没有 provider 有效期,归属时刻 = 标记时刻(不同于陈旧归属)。
        let manuallyMarkedAt: Date? = {
            if case .manuallyExpired(let markedAt) = plan { return markedAt }
            return nil
        }()

        return VStack(alignment: .leading, spacing: 10) {
            header(expired: expired)
            // 到期结论的陈旧归属(#54):订阅数据过旧时,「已到期」说清断言从哪一刻的数据来。
            // 手动态不走这条(用户的标记没有「陈旧」一说),归属在数据区里标「手动标记于」。
            if expired, case .expired(_, let observedAt) = plan,
               let attribution = Presentation.staleValidityAttribution(
                   observedAt: observedAt,
                   now: now,
                   threshold: Thresholds().expiryStalenessThreshold
               ) {
                Text(attribution)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            if let snapshot = runtime.snapshot, runtime.credential == .configured {
                if runtime.loadFailed {
                    loadFailureArea(expired: expired)
                }
                dataContent(snapshot, expired: expired, manuallyMarkedAt: manuallyMarkedAt, now: now)
            } else if runtime.credential == .invalid {
                CredentialPlaceholder(
                    title: "凭据失效",
                    message: "该 provider 无法拉取用量,请到设置中重新填写凭据",
                    provider: provider,
                    model: model,
                    showsSettingsAction: true
                )
            } else if runtime.credential == .missing {
                CredentialPlaceholder(
                    title: isCredentialReadFailure ? "凭据状态未知" : "未配置凭据",
                    message: isCredentialReadFailure
                        ? "钥匙串读取失败,无法确认该 provider 的凭据是否已配置"
                        : "粘贴 \(provider.displayName) 的凭据后可拉取用量",
                    provider: provider,
                    model: model,
                    showsSettingsAction: true
                )
            } else if runtime.loadFailed {
                LoadFailurePlaceholder(provider: provider, runtime: runtime, model: model)
            } else {
                Text("正在获取数据…")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }

            actions(manuallyMarkedAt: manuallyMarkedAt)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - 头部

    private func header(expired: Bool) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Presentation.color(for: statusForHeader(expired: expired), scheme: scheme))
                .frame(width: 8, height: 8)
            Text(provider.displayName)
                .font(.system(size: 13.5, weight: .semibold))
            // P2-9(FC-6):胶囊只显 level;内部域码进 tooltip(展示层映射已知值)。
            if let plan = runtime.snapshot?.meta.plan {
                planCapsule(plan)
            }
            Spacer()
            if runtime.hasSnapshot, runtime.credential == .configured {
                // 到期(#54):头部状态位换灰「已到期」——到期是「还适不适用」,不与健康档同台。
                Text(expired ? Presentation.planExpiredLabel : Presentation.label(for: runtime.status))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
    private func statusForHeader(expired: Bool) -> ProviderStatus? {
        guard runtime.hasSnapshot, runtime.credential == .configured, !expired else { return nil }
        return runtime.status
    }

    /// 钥匙串读取异常:凭据状态未知,不误判为「未配置」。
    private var isCredentialReadFailure: Bool {
        model.state.credentialReadFailures.contains(provider)
    }

    @ViewBuilder
    private func planCapsule(_ plan: Plan) -> some View {
        let capsule = Text(plan.level)
            .font(.system(size: 10))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .foregroundStyle(.secondary)
        if let domain = plan.domain {
            capsule.help(Presentation.planDomainHelp(domain))
        } else {
            capsule
        }
    }

    // MARK: - 数据内容

    @ViewBuilder
    private func dataContent(_ snapshot: Snapshot, expired: Bool, manuallyMarkedAt: Date?, now: Date) -> some View {
        // 手动标记的归属(#58):「手动标记于 MM-dd」放在数据区头部——Kimi 没有
        // 「有效期至」行,这里就是它的来历说明,不冒充官方事实。
        if let manuallyMarkedAt {
            Text(Presentation.manualExpiryAttribution(manuallyMarkedAt))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }

        // 主区:「额度窗口」——只放 plan 窗(频限窗移入下方次级区,P2-6)。
        // 到期(#54):窗口行换灰化形态——数值保留但灰化,百分比/进度条/重置行全撤,
        // 死数据不冒充活结论;余额/钱包与「近 7 天消耗」不跟着灰(仍是可用/已发生的事实)。
        ForEach(Array(snapshot.planWindows.enumerated()), id: \.offset) { _, window in
            QuotaWindowRow(window: window, fromFailedSnapshot: runtime.loadFailed, expired: expired)
        }

        // 套餐有效期(#53):只在拿到订阅记录时出现;分片失败 / 无订阅记录时该行干脆不出现,
        // 其它字段与今天完全一致(静默退化)。到期后灰化保留末端日期(#54)。
        if let validity = snapshot.planValidity {
            InfoRow(label: "有效期至", value: validityText(validity, expired: expired, now: now), valueIsMuted: expired)
        }

        if provider == .deepseek {
            DeepSeekBalanceBlock(snapshot: snapshot)
        } else {
            ForEach(Array(snapshot.balances.enumerated()), id: \.offset) { _, balance in
                InfoRow(label: balanceLabel(balance), value: Money.format(balance.amount, currency: balance.currency))
            }
            // 并发上限移入次级区(P2-6):常量事实不与动态额度混排。
        }

        // 无直接来源的 provider 根本不出现该行;有来源但获取失败显示「— 获取失败」。
        // FC-4:「近 7 天消耗」(自然滚动累计,单位 tokens)与「7 天窗」(订阅锚窗剩余,积分)
        // 是两个口径,文案上可区分,不再像同一件事的两种说法。
        let rollingLabel = "近 7 天消耗"
        switch snapshot.rollingUsage {
        case .value(let amount, let unit):
            InfoRow(label: rollingLabel, value: "\(Money.formatCount(amount)) \(unit)")
        case .failed:
            InfoRow(label: rollingLabel, value: "— 获取失败", valueIsMuted: true)
                .help("该行依赖独立的用量时序接口,获取失败不影响其它额度数据")
        case nil:
            EmptyView()
        }

        // 次级区(P2-6,FC-3):频限单行 + 并发上限——更小字号、次要色、单行化,
        // 与主区拉开层级;只在确有次级事实时渲染。
        secondaryFactsZone(snapshot)
    }

    @ViewBuilder
    private func secondaryFactsZone(_ snapshot: Snapshot) -> some View {
        let rateLimits = snapshot.rateLimitWindows
        let concurrency = snapshot.meta.concurrencyLimit
        if !rateLimits.isEmpty || concurrency != nil {
            VStack(alignment: .leading, spacing: 2.5) {
                // 恢复时刻的过期降级需分钟级重估(与主区 resetLine 同语义);
                // EveryMinute 仅 popover 挂载时运转,无全局定时器。
                EveryMinute { now in
                    ForEach(Array(rateLimits.enumerated()), id: \.offset) { _, window in
                        let line = RateLimitFactLine(window: window, fromFailedSnapshot: runtime.loadFailed, now: now)
                        if let help = line.help {
                            Text(line.text)
                                .help(help)
                        } else {
                            Text(line.text)
                        }
                    }
                }
                if let concurrency {
                    Text("并发上限 \(concurrency)")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .overlay(alignment: .top) { Divider().opacity(0.4) }
        }
    }

    private func balanceLabel(_ balance: Balance) -> String {
        switch balance.type {
        case .topUp: return "充值"
        case .granted: return "赠送"
        case .wallet: return "booster 钱包"
        }
    }

    /// 有效期行的值:MM-dd(北京时间);未到期且剩 ≤ 提醒天数时补「(剩 N 天)」
    /// (临界期不用自己算日期);到期后不加后缀(到期态由灰化形态自己说话)。
    private func validityText(_ validity: PlanValidity, expired: Bool, now: Date) -> String {
        var text = Presentation.validityDate(validity.validUntil)
        if !expired,
           let suffix = Presentation.expiringSoonSuffix(
               validUntil: validity.validUntil,
               now: Date(),
               reminderDays: Thresholds().expiryReminderDays
           ) {
            text += suffix
        }
        return text
    }

    /// 额度失败区的分档(#54):未到期 → 既有橙色「加载失败」条;到期 → 「已到期」优先,
    /// 灰条只说「额度未能刷新(最后成功 HH:mm)」——排定的到期不被误诊成网络问题。
    @ViewBuilder
    private func loadFailureArea(expired: Bool) -> some View {
        if expired {
            expiredQuotaStrip
        } else {
            failureStrip
        }
    }

    private var expiredQuotaStrip: some View {
        HStack(spacing: 6) {
            Text(expiredQuotaStripText)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button("重试") { model.refresh(provider) }
                .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    private var expiredQuotaStripText: String {
        if let at = runtime.lastSuccessAt {
            return "额度未能刷新(最后成功 \(Presentation.time(at)))"
        }
        return "额度未能刷新,稍后自动重试"
    }

    private var failureStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text("加载失败")
                    .font(.system(size: 11.5, weight: .semibold))
                Text(lastSuccessText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("重试") { model.refresh(provider) }
                .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private var lastSuccessText: String {
        if let at = runtime.lastSuccessAt {
            return "显示的是 \(Presentation.time(at) ) 的最后一次成功数据"
        }
        return "网络错误或接口超时,稍后自动重试"
    }

    // MARK: - 动作区

    private func actions(manuallyMarkedAt: Date?) -> some View {
        HStack(spacing: 8) {
            if model.refreshingProvider == provider {
                ProgressView()
                    .controlSize(.small)
            }
            // 手动标记到期(#58):只给 App 无从得知有效期的家(Kimi),标记与还原同一位。
            // 门控与「已到期」形态一致(凭据正常 + 持快照):按钮能看到自己造成的形态变化,
            // 不产生「点了没反应」的隐形状态;凭据坏时的维护入口在设置窗口。
            if showsManualPlanExpiryControl {
                Button(Presentation.manualExpiryActionTitle(marked: manuallyMarkedAt != nil)) {
                    model.setManualPlanExpiry(marked: manuallyMarkedAt == nil, for: provider)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11.5))
                .help(manuallyMarkedAt == nil
                    ? "App 无法自动得知该家的有效期;标记后按「已到期」呈现(数值保留但灰化、退出全局结论)"
                    : "续订后恢复显示:解除到期形态,按当前数据重新参与结论")
            }
            Spacer()
            // 卡级「刷新」已移除(P2-8,I):与头部全量刷新同名同图不同义;
            // 非失败态不再提供卡级刷新(头部全量覆盖),失败态的重试入口在
            // 上方的失败条/占位里(单家语义,不与「刷新」并存)。
            Link(destination: provider.consoleURL) {
                Text("控制台 ↗")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.borderless)
            .help("在浏览器打开官方用量页")
        }
    }
    /// 手动标记入口的成立条件(#58):有手动入口的家 + 凭据正常 + 持快照
    /// (与「已到期」形态同一个门控——标记能立刻在卡上看到自己的结果)。
    private var showsManualPlanExpiryControl: Bool {
        provider.supportsManualPlanExpiry && runtime.credential == .configured && runtime.hasSnapshot
    }

}

// MARK: - 行与占位

struct QuotaWindowRow: View {
    let window: QuotaWindow
    /// 该行数据是否来自「加载失败」期间仍持有的旧快照:已过期的重置时间需降灰标注,
    /// 不误导为有效倒计时。(与图标的「陈旧」概念不同:那个看 2× 轮询间隔,不看失败态。)
    var fromFailedSnapshot = false
    /// 到期形态(#54):数值保留但灰化(次要色、去强调字重),百分比/进度条/重置行全撤——
    /// 到期是「这条数据不能当结论用」,不是「这条数据不存在」。
    var expired = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Money.formatCount(window.remaining))
                    .font(.system(size: 11.5, weight: expired ? .regular : .semibold))
                    .foregroundStyle(expired ? Color.secondary : Color.primary)
                    .monospacedDigit()
                Text("/ \(Money.formatCount(window.limit)) \(window.unit)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                // FC-2:行尾 muted 剩余百分比,与 tab 速览 / 总览同源同口径
                // (Percent.display),互证「全局最紧」的数字从哪条窗来。
                // 到期后撤下:百分比是结论性断言,死数据不带结论。
                if !expired, let fraction = window.remainingFraction {
                    Text("(\(Percent.display(fraction))%)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            // 进度条与重置倒计时都是「还会继续」的前瞻声明,到期后全撤(数值保留即可)。
            if !expired {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(tint)
                resetLine
            }
        }
    }

    /// 重置行(骨架F+FC-1):分档倒计时,绝对时刻进 tooltip。
    @ViewBuilder
    private var resetLine: some View {
        if let resetAt = window.resetAt {
            EveryMinute { now in
                if fromFailedSnapshot, resetAt <= now {
                    Text("已过期(最后成功快照)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary.opacity(0.7))
                } else {
                    Text(Presentation.resetCountdown(resetAt, now: now))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help(Presentation.absoluteReset(resetAt))
                }
            }
        }
    }

    private var progress: Double {
        guard window.limit > 0 else { return 0 }
        return min(1, max(0, Double(window.used) / Double(window.limit)))
    }

    /// 进度条色(FC-7,克制版):规则见 `WindowBarTint`;中性档用克制的灰,
    /// 不再与状态点争「好色」的发言权。
    private var tint: Color {
        switch WindowBarTint.of(kind: window.kind, remainingFraction: window.remainingFraction) {
        case .alertRed: return .red
        case .alertYellow: return .yellow
        case .neutral: return Self.neutralFill
        }
    }

    private static let neutralFill = Color.secondary.opacity(0.6)
}

struct InfoRow: View {
    let label: String
    let value: String
    var valueIsMuted = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11.5, weight: valueIsMuted ? .regular : .semibold))
                .foregroundStyle(valueIsMuted ? Color.secondary : Color.primary)
                .monospacedDigit()
        }
        .padding(.top, 2)
        .overlay(alignment: .top) { Divider().opacity(0.4) }
    }
}

/// DeepSeek:余额总额 + 充值/赠送构成(按币种拆分展示,不做跨源换算)。
struct DeepSeekBalanceBlock: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if snapshot.meta.accountAvailable == false {
                unavailableStrip
            }
            if let currency = snapshot.primaryCurrency {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(Money.format(snapshot.totalBalance(currency: currency), currency: currency))
                        .font(.system(size: 24, weight: .bold))
                        .monospacedDigit()
                }
                ForEach(snapshot.currencies, id: \.self) { currency in
                    InfoRow(label: "\(currency) 构成", value: composition(currency))
                }
            }
        }
    }

    /// FC-5:官方标记不可用 → 余额上方红色内联条(复用加载失败条的视觉,文案不带 API 字段名);
    /// 账户正常时不渲染任何可用性行(常态「可用」是纯噪音)。
    private var unavailableStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 11))
            Text("官方标记账户不可用,以下为最后快照余额")
                .font(.system(size: 11.5, weight: .semibold))
            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
    }

    private func composition(_ currency: String) -> String {
        let topUp = snapshot.balances(ofType: .topUp)
            .filter { $0.currency == currency }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let granted = snapshot.balances(ofType: .granted)
            .filter { $0.currency == currency }
            .reduce(Decimal.zero) { $0 + $1.amount }
        return "充值 \(Money.format(topUp)) · 赠送 \(Money.format(granted))"
    }
}

struct CredentialPlaceholder: View {
    let title: String
    let message: String
    let provider: Provider
    @ObservedObject var model: AppModel
    var showsSettingsAction: Bool

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "key")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                if showsSettingsAction {
                    Button("去设置") {
                        model.openSettings(selecting: .provider(provider))
                    }
                }
                Button("重试") { model.refresh(provider) }
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }
}

struct LoadFailurePlaceholder: View {
    let provider: Provider
    let runtime: ProviderRuntimeState
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
            Text("加载失败")
                .font(.system(size: 12.5, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") { model.refresh(provider) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        if let at = runtime.lastSuccessAt {
            return "网络错误或接口超时 · 上次成功 \(Presentation.time(at))"
        }
        if let descriptor = runtime.failureDescriptor {
            return "网络错误或接口超时 · \(descriptor)"
        }
        return "网络错误或接口超时"
    }
}
