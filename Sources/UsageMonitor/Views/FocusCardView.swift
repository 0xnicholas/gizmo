import SwiftUI
import UsageMonitorCore

/// 焦点卡片:按数据模型只渲染存在的字段;错误/失效/缺失有各自的占位形态。
struct FocusCardView: View {
    let provider: Provider
    let runtime: ProviderRuntimeState
    @ObservedObject var model: AppModel

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
                    title: "未配置凭据",
                    message: "粘贴 \(provider.displayName) 的凭据后可拉取用量",
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
                .fill(Presentation.color(for: statusForHeader))
                .frame(width: 8, height: 8)
            Text(provider.displayName)
                .font(.system(size: 13.5, weight: .semibold))
            if let plan = runtime.snapshot?.meta.plan {
                Text(planText(plan))
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .foregroundStyle(.secondary)
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

    private func planText(_ plan: Plan) -> String {
        if let domain = plan.domain, domain != plan.level {
            return "\(plan.level) · \(domain)"
        }
        return plan.level
    }

    // MARK: - 数据内容

    @ViewBuilder
    private func dataContent(_ snapshot: Snapshot) -> some View {
        ForEach(Array(snapshot.windows.enumerated()), id: \.offset) { _, window in
            QuotaWindowRow(window: window)
        }

        if provider == .deepseek {
            DeepSeekBalanceBlock(snapshot: snapshot)
        } else {
            ForEach(Array(snapshot.balances.enumerated()), id: \.offset) { _, balance in
                InfoRow(label: balanceLabel(balance), value: Money.format(balance.amount, currency: balance.currency))
            }
            if let concurrency = snapshot.meta.concurrencyLimit {
                InfoRow(label: "并发上限", value: "\(concurrency)")
            }
        }

        // 无直接来源的 provider 根本不出现该行;有来源但获取失败显示「— 获取失败」。
        switch snapshot.rollingUsage {
        case .value(let amount, let unit):
            InfoRow(label: "近 7 天用量", value: "\(Money.formatCount(amount)) \(unit)")
        case .failed:
            InfoRow(label: "近 7 天用量", value: "— 获取失败", valueIsMuted: true)
        case nil:
            EmptyView()
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
            Button("刷新") { model.refresh(provider) }
                .controlSize(.small)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(window.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(window.remaining)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                Text("/ \(window.limit) \(window.unit)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(tint)
            if let reset = Presentation.resetText(window.resetAt) {
                Text(reset)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progress: Double {
        guard window.limit > 0 else { return 0 }
        return min(1, max(0, Double(window.used) / Double(window.limit)))
    }

    /// 频限窗不参与 status 判定,进度条只用中性色。
    private var tint: Color {
        guard window.kind == .planWindow, let fraction = window.remainingFraction else { return .accentColor }
        switch fraction {
        case ..<0.10: return .red
        case ..<0.30: return .yellow
        default: return .accentColor
        }
    }
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
            if let available = snapshot.meta.accountAvailable {
                InfoRow(label: "可用状态", value: available ? "可用" : "不可用(is_available=false)")
            }
        }
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
            Image(systemName: "key.slash")
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
