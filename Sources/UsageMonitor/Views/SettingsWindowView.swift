import SwiftUI
import UsageMonitorCore

/// 设置窗口:左侧 provider 列表(含状态圆点)+ 顶部「通用」分组,右侧详情窗格。
struct SettingsWindowView: View {
    @ObservedObject var model: AppModel

    @State private var draft: [Provider: String] = [:]
    @State private var revealed: Set<Provider> = []
    @State private var confirmingClear: Provider?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(width: 560, height: 340)
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            sidebarRow(title: "通用", selected: model.settingsSelection == .general) {
                model.settingsSelection = .general
            }
            Divider().padding(.vertical, 4)
            ForEach(Provider.allCases, id: \.self) { provider in
                sidebarRow(title: provider.displayName, selected: model.settingsSelection == .provider(provider)) {
                    model.settingsSelection = .provider(provider)
                    model.settingsArrivalBanner = false
                } leading: {
                    Circle()
                        .fill(color(state(provider).credential))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 176, alignment: .leading)
    }

    private func sidebarRow(
        title: String,
        selected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder leading: () -> some View = { EmptyView() }
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                leading()
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.15) : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 详情

    @ViewBuilder
    private var detail: some View {
        switch model.settingsSelection {
        case .general:
            generalPane
        case .provider(let provider):
            credentialPane(provider)
        }
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("通用")
                .font(.system(size: 14, weight: .semibold))
            Toggle("登录时启动", isOn: Binding(
                get: { model.loginItemEnabled },
                set: { model.setLoginItem(enabled: $0) }
            ))
            .toggleStyle(.switch)
            Text("登录后自动在菜单栏常驻(用户级 LaunchAgent)。关闭不影响本次运行;结束本次运行请用 popover 里的「退出用量监视器」。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Divider()
            Text("凭据与快照只在本机:凭据存系统钥匙串,最近一次成功快照存 Application Support;不做任何上传。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("完成") { model.requestCloseSettings?() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func credentialPane(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(provider.displayName) · 凭据")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                statusCapsule(state(provider).credential)
            }

            if model.settingsArrivalBanner {
                banner(
                    text: "正在为 \(provider.displayName) 更新凭据(来自失效提示)",
                    color: .accentColor
                )
            }
            if let notice = model.credentialNotices[provider] {
                switch notice {
                case .saved:
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("已保存到钥匙串").font(.system(size: 11.5))
                    }
                case .error(let message):
                    banner(text: message, color: .red)
                }
            }

            field(for: provider)

            Text(hint(for: provider) + " 保存时自动去除首尾空白。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("保存到钥匙串") { save(provider) }
                    .keyboardShortcut(.defaultAction)
                Spacer()
                clearControls(provider)
            }

            Divider()
            Text("凭据与 pi 无关,由本 app 自管;值只写入系统钥匙串并在进程内使用,不落日志、不进快照。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("完成") { model.requestCloseSettings?() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(for provider: Provider) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "lock")
                .foregroundStyle(.secondary)
            Group {
                if revealed.contains(provider) {
                    TextField(placeholder(provider), text: binding(provider))
                } else {
                    SecureField(placeholder(provider), text: binding(provider))
                }
            }
            .textFieldStyle(.roundedBorder)
            Button(revealed.contains(provider) ? "隐藏" : "显示") {
                if revealed.contains(provider) {
                    revealed.remove(provider)
                } else {
                    revealed.insert(provider)
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
    }

    @ViewBuilder
    private func clearControls(_ provider: Provider) -> some View {
        if confirmingClear == provider {
            HStack(spacing: 6) {
                Text("清除后该家无法拉取用量")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("清除") {
                    model.clearCredential(for: provider)
                    draft[provider] = ""
                    confirmingClear = nil
                }
                .tint(.red)
                Button("取消") { confirmingClear = nil }
            }
        } else {
            Button("清除凭据…") { confirmingClear = provider }
                .disabled(state(provider).credential == .missing)
        }
    }

    private func banner(text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).font(.system(size: 11.5))
            Spacer()
        }
        .padding(7)
        .foregroundStyle(color)
        .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(0.12)))
    }

    private func statusCapsule(_ credential: CredentialState) -> some View {
        Text(statusText(credential))
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color(credential).opacity(0.18)))
            .foregroundStyle(color(credential))
    }

    // MARK: - 绑定与文案

    private func state(_ provider: Provider) -> ProviderRuntimeState {
        model.state.provider(provider)
    }

    private func binding(_ provider: Provider) -> Binding<String> {
        Binding(
            get: { draft[provider] ?? "" },
            set: { newValue in
                draft[provider] = newValue
                if !newValue.isEmpty {
                    model.dismissCredentialNotice(for: provider)
                }
            }
        )
    }

    private func save(_ provider: Provider) {
        let value = draft[provider] ?? ""
        // 只有写入成功才清空输入框,失败时保留用户粘贴的内容。
        if model.saveCredential(value, for: provider) {
            draft[provider] = ""
        }
    }

    private func placeholder(_ provider: Provider) -> String {
        switch provider {
        case .deepseek: return state(provider).credential == .configured ? "已配置 · 粘贴新值可覆盖" : "sk-…"
        case .kimi: return state(provider).credential == .configured ? "已配置 · 粘贴新值可覆盖" : "粘贴 Kimi for Coding token…"
        case .glm: return state(provider).credential == .configured ? "已配置 · 粘贴新值可覆盖" : "粘贴 GLM 套餐 API key…"
        }
    }

    private func hint(for provider: Provider) -> String {
        switch provider {
        case .deepseek: return "粘贴 API key(sk- 开头,作为 Bearer 使用)。"
        case .kimi: return "粘贴访问 token(整段复制)。"
        case .glm: return "粘贴套餐 API key(裸 key,无 Bearer 前缀)。"
        }
    }

    private func statusText(_ credential: CredentialState) -> String {
        switch credential {
        case .configured: return "已配置"
        case .invalid: return "已失效 · 重存即覆盖"
        case .missing: return "未配置"
        }
    }

    private func color(_ credential: CredentialState) -> Color {
        switch credential {
        case .configured: return .green
        case .invalid: return .red
        case .missing: return .secondary
        }
    }
}
