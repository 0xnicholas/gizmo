import SwiftUI
import UsageMonitorCore

/// popover = 总览 + 焦点:顶部「全局最紧」总览条 + 三家标签页 + 焦点卡片。
struct PopoverView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    private var state: EngineState { model.state }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    bannerContent
                    GlobalOverviewBar(state: state)
                    providerTabs
                    FocusCardView(provider: model.focusProvider, runtime: state.provider(model.focusProvider), model: model)
                    credentialStatusRow
                }
                .padding(12)
            }
            .frame(height: 430)
            Divider()
            footer
        }
        .frame(width: 360)
        .onAppear { model.popoverOpened() }
        .onDisappear { model.popoverClosed() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Text("用量监视器")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button {
                Task { await model.refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .opacity(model.isRefreshing ? 0.4 : 1)
            }
            .buttonStyle(.borderless)
            .help("立即刷新三家用量")
            Button {
                model.openSettings(selecting: .general)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("设置(凭据、登录自启)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - 凭据汇总横幅(同一次打开会话内可关闭,下次打开仍失效则重现)

    @ViewBuilder
    private var bannerContent: some View {
        if !model.bannerDismissed, state.pendingCredentialCount > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bannerText)
                        .font(.system(size: 12, weight: .semibold))
                    Text("凭据状态:已配置 / 未配置 / 已失效")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(bannerActionTitle) {
                    if let first = firstPendingProvider {
                        model.openSettings(selecting: .provider(first))
                    } else {
                        model.openSettings(selecting: .general)
                    }
                }
                .controlSize(.small)
                Button {
                    model.bannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("关闭(下次打开仍失效则重现)")
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.12)))
        }
    }

    private var bannerText: String {
        var parts: [String] = []
        if state.invalidCredentialCount > 0 {
            parts.append("\(state.invalidCredentialCount) 家凭据失效")
        }
        if state.missingCredentialCount > 0 {
            parts.append("尚未配置凭据")
        }
        return parts.joined(separator: " · ")
    }

    /// 规格文案:失效 →「去设置」;未配置 →「开始配置」。
    private var bannerActionTitle: String {
        state.invalidCredentialCount > 0 ? "去设置" : "开始配置"
    }

    private var firstPendingProvider: Provider? {
        Provider.displayOrder.first { state.provider($0).credential == .invalid }
            ?? Provider.displayOrder.first {
                state.provider($0).credential == .missing && !state.credentialReadFailures.contains($0)
            }
    }

    // MARK: - 标签页

    private var providerTabs: some View {
        HStack(spacing: 4) {
            ForEach(Provider.displayOrder, id: \.self) { provider in
                Button {
                    model.focusProvider = provider
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Presentation.color(for: tabStatus(provider), scheme: scheme))
                            .frame(width: 7, height: 7)
                        Text(shortName(provider))
                            .font(.system(size: 11.5, weight: model.focusProvider == provider ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(model.focusProvider == provider ? Color.primary.opacity(0.08) : .clear)
                )
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
    }

    private func tabStatus(_ provider: Provider) -> ProviderStatus? {
        let runtime = state.provider(provider)
        return runtime.hasSnapshot ? runtime.status : nil
    }

    private func shortName(_ provider: Provider) -> String {
        switch provider {
        case .glm: return "GLM"
        case .kimi: return "Kimi"
        case .deepseek: return "DeepSeek"
        }
    }

    // MARK: - 凭据状态行(骨架C,P1-5:全绿收一行,有问题只展开问题家)

    private var credentialStatusRow: some View {
        let rowPresentation = CredentialRowPresentation(state: state)
        return VStack(alignment: .leading, spacing: 5) {
            if rowPresentation.isCollapsed {
                // 全绿:一行「三家凭据正常 · 管理」,把纵向空间还给总览与焦点卡;
                // 行文已自证是凭据段,不再叠小标题。
                HStack(spacing: 6) {
                    Circle()
                        .fill(credentialColor(.configured))
                        .frame(width: 6, height: 6)
                    Text("三家凭据正常")
                        .font(.system(size: 11))
                    Spacer()
                    Button("管理") {
                        model.openSettings(selecting: .general)
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
                    .help("打开设置;凭据在左侧列表逐家管理")
                }
            } else {
                Text("凭据")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(rowPresentation.problemProviders, id: \.self) { provider in
                    problemCredentialRow(provider)
                }
            }
        }
    }

    /// 问题家逐行:名称 + 状态 + 入口;正常家不占行(横幅管汇总,行管逐家入口)。
    private func problemCredentialRow(_ provider: Provider) -> some View {
        let runtime = state.provider(provider)
        let readFailure = state.credentialReadFailures.contains(provider)
        return HStack(spacing: 6) {
            Circle()
                .fill(readFailure ? Color.secondary.opacity(0.5) : credentialColor(runtime.credential))
                .frame(width: 6, height: 6)
            Text(provider.displayName)
                .font(.system(size: 11))
            Text(readFailure ? "未知(钥匙串读取失败)" : credentialText(runtime.credential))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer()
            Button(isConfigured(provider) || readFailure ? "管理" : "去设置") {
                model.openSettings(selecting: .provider(provider))
            }
            .buttonStyle(.borderless)
            .font(.system(size: 10.5))
        }
    }

    private func isConfigured(_ provider: Provider) -> Bool {
        state.provider(provider).credential == .configured
    }

    private func credentialColor(_ credential: CredentialState) -> Color {
        switch credential {
        case .configured: return .green
        case .invalid: return .red
        case .missing: return Color.secondary.opacity(0.5)
        }
    }

    private func credentialText(_ credential: CredentialState) -> String {
        switch credential {
        case .configured: return "已配置"
        case .invalid: return "凭据失效"
        case .missing: return "未配置"
        }
    }

    // MARK: - 脚注

    private var footer: some View {
        HStack(spacing: 6) {
            if let updated = state.lastUpdatedAt {
                // 骨架F:相对化「N 分钟前更新」,≥1h 退回绝对。
                EveryMinute { now in
                    Text(Presentation.updatedAgo(updated, now: now))
                }
            } else {
                Text("尚未刷新")
            }
            Spacer()
            Text("自动刷新 30 分钟")
                .help("每 30 分钟后台轮询三家;单家连续失败 3 轮(≈90 分钟)显示加载失败;打开本面板与手动刷新即时生效。")
            Button("退出用量监视器") { model.quit() }
                .buttonStyle(.borderless)
                .help("结束本次运行(不影响登录自启设置)")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// 顶部「全局最紧」总览条:与菜单栏图标同口径(全部 plan-window 的最低剩余)。
struct GlobalOverviewBar: View {
    let state: EngineState
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            ZStack {
                Circle()
                    .fill(Presentation.color(for: state.overview.worstStatus, scheme: scheme))
                    .frame(width: 22, height: 22)
                Text(symbolText)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                // 重置时刻走分档倒计时(骨架F)。
                EveryMinute { now in
                    Text(subtitle(now: now))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                if let alertLine {
                    Text(alertLine)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Presentation.color(for: state.overview.worstStatus, scheme: scheme))
                }
            }
            Spacer()
            // 全局结论扶正(骨架A,P0-2):大号百分比与菜单栏图标同源同口径,免读整句副行。
            let figure = GlobalPercentPresentation(state: state, scheme: scheme)
            Text(figure.text)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(figure.color)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var symbolText: String {
        Presentation.symbol(for: state.overview.worstStatus)
    }

    /// 全新安装:从未配置过任何凭据且无任何快照;读取异常不算(状态未知时不误判,同首启引导口径)。
    private var isFreshInstall: Bool {
        state.overview.snapshotCount == 0
            && !state.hasAnyCredential
            && state.credentialReadFailures.isEmpty
    }

    private var title: String {
        // 从未配置过任何凭据:不会有任何获取,不留「正在获取」的错觉。
        if isFreshInstall {
            return "尚未配置凭据"
        }
        guard let tightest = state.overview.tightest else {
            return state.overview.snapshotCount > 0 ? "暂无窗口数据" : "正在获取用量…"
        }
        return "全局最紧:\(tightest.provider.displayName) · \(tightest.windowLabel)"
    }

    private func subtitle(now: Date) -> String {
        if isFreshInstall {
            return "菜单栏图标显示「—」;粘贴凭据后自动开始刷新"
        }
        guard let tightest = state.overview.tightest else {
            return "菜单栏图标显示「—」,直到有套餐窗口数据"
        }
        var text = "剩余 \(Money.formatCount(tightest.remaining)) / \(Money.formatCount(tightest.limit)) \(tightest.unit)"
        if let resetAt = tightest.resetAt {
            text += " · \(Presentation.resetCountdown(resetAt, now: now))"
        }
        // 骨架E(P0-4):最紧家加载失败时,副行承认数字是旧的(复用焦点卡「最后成功」口径)。
        let tightestRuntime = state.provider(tightest.provider)
        if tightestRuntime.loadFailed, let lastSuccess = tightestRuntime.lastSuccessAt {
            text += "(最后成功 \(Presentation.time(lastSuccess)))"
        }
        return text
    }

    /// 临界/偏低的落点单独一行:最紧的窗口未必就是拉低颜色的那家
    /// (如 DeepSeek 无窗口、按余额分界),避免把结论挂错行。
    private var alertLine: String? {
        let criticals = providers(withStatus: .critical)
        if !criticals.isEmpty {
            return "已达临界:" + criticals.map(\.displayName).joined(separator: "、")
        }
        let lows = providers(withStatus: .low)
        if !lows.isEmpty {
            return "偏低:" + lows.map(\.displayName).joined(separator: "、")
        }
        return nil
    }

    private func providers(withStatus status: ProviderStatus) -> [Provider] {
        Provider.displayOrder.filter { provider in
            let runtime = state.provider(provider)
            return runtime.hasSnapshot && runtime.credential == .configured && runtime.status == status
        }
    }
}
