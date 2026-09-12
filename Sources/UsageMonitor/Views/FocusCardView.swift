import SwiftUI
import UsageMonitorCore

/// 焦点卡片:按数据模型只渲染存在的字段;错误/失效/缺失有各自的占位形态。
struct FocusCardView: View {
    let provider: Provider
    let runtime: ProviderRuntimeState
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let snapshot = runtime.snapshot, runtime.credential == .configured {
                if runtime.loadFailed {
                    failureStrip
                }
                dataContent(snapshot)
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

            actions
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Presentation.color(for: statusForHeader, scheme: scheme))
                .frame(width: 8, height: 8)
            Text(provider.displayName)
                .font(.system(size: 13.5, weight: .semibold))
            // P2-9(FC-6):胶囊只显 level;内部域码进 tooltip(展示层映射已知值)。
            if let plan = runtime.snapshot?.meta.plan {
                planCapsule(plan)
            }
            Spacer()
            if runtime.hasSnapshot, runtime.credential == .configured {
                Text(Presentation.label(for: runtime.status))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
    private var statusForHeader: ProviderStatus? {
        guard runtime.hasSnapshot, runtime.credential == .configured else { return nil }
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
    private func dataContent(_ snapshot: Snapshot) -> some View {
        // 主区:「额度窗口」——只放 plan 窗(频限窗移入下方次级区,P2-6)。
        ForEach(Array(snapshot.planWindows.enumerated()), id: \.offset) { _, window in
            QuotaWindowRow(window: window, fromFailedSnapshot: runtime.loadFailed)
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

    private var actions: some View {
        HStack(spacing: 8) {
            if model.refreshingProvider == provider {
                ProgressView()
                    .controlSize(.small)
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
}

// MARK: - 行与占位

struct QuotaWindowRow: View {
    let window: QuotaWindow
    /// 该行数据是否来自「加载失败」期间仍持有的旧快照:已过期的重置时间需降灰标注,
    /// 不误导为有效倒计时。(与图标的「陈旧」概念不同:那个看 2× 轮询间隔,不看失败态。)
    var fromFailedSnapshot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Money.formatCount(window.remaining))
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                Text("/ \(Money.formatCount(window.limit)) \(window.unit)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                // FC-2:行尾 muted 剩余百分比,与图标/总览同源同口径
                // (Percent.display),互证「全局最紧」的数字从哪条窗来。
                if let fraction = window.remainingFraction {
                    Text("(\(Percent.display(fraction))%)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(tint)
            resetLine
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
