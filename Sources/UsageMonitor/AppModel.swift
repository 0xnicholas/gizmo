import AppKit
import Combine
import SwiftUI
import UsageMonitorCore

/// 应用状态的单一持有者:把引擎事件翻译为 UI 状态与本地通知,并驱动三层刷新。
///
/// 引擎(UsageMonitorCore)负责全部策略;这一层只做适配与呈现。
@MainActor
final class AppModel: ObservableObject {
    enum SettingsSelection: Hashable {
        case general
        case provider(Provider)
    }

    /// 窗格内一次性反馈(保存成功 / 钥匙串写入失败)。
    enum CredentialNotice: Equatable {
        case saved
        case error(String)
    }

    struct Notice: Equatable, Identifiable {
        enum Kind: Equatable { case error, info }
        let id = UUID()
        var kind: Kind
        var text: String
    }

    private enum DefaultsKey {
        static let didGuide = "didGuideFirstRun"
        static let loginItemPreferenceKnown = "loginItemPreferenceKnown"
    }

    @Published private(set) var state: EngineState
    @Published var focusProvider: Provider = .glm
    @Published private(set) var refreshingProvider: Provider?
    @Published private(set) var isRefreshing = false
    @Published var bannerDismissed = false
    @Published var settingsSelection: SettingsSelection = .general
    @Published var settingsArrivalBanner = false
    @Published private(set) var credentialNotices: [Provider: CredentialNotice] = [:]
    @Published var notice: Notice?
    @Published private(set) var loginItemEnabled = LoginItem.isEnabled

    /// 由 AppDelegate 注入:打开设置窗口(选中某家 / 带「正在更新凭据」横幅)。
    var requestOpenSettings: ((SettingsSelection, Bool) -> Void)?
    /// 由 AppDelegate 注入:设置窗口「完成」关闭按钮。
    var requestCloseSettings: (() -> Void)?

    private let engine: UsageEngine
    private let credentials: any CredentialStore
    private let presenter = NotificationPresenter()
    private let defaults: UserDefaults
    private var pollTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        credentials: any CredentialStore = KeychainCredentialStore(),
        thresholds: Thresholds = Thresholds()
    ) {
        self.defaults = defaults
        self.credentials = credentials
        let clock = SystemClock()
        self.state = EngineState(providers: Dictionary(
            uniqueKeysWithValues: Provider.allCases.map { ($0, ProviderRuntimeState(provider: $0)) }
        ))
        self.engine = UsageEngine(
            credentials: credentials,
            fetchers: [
                .deepseek: DeepSeekFetcher(),
                .kimi: KimiFetcher(),
                .glm: GLMFetcher(clock: clock),
            ],
            parsers: [
                .deepseek: DeepSeekParser(),
                .kimi: KimiParser(),
                .glm: GLMParser(),
            ],
            cache: FileSnapshotCache(),
            clock: clock,
            thresholds: thresholds
        )

        presenter.onOpen = { [weak self] route in
            self?.handleNotificationRoute(route)
        }
    }

    #if DEBUG
    /// 仅供开发期离屏渲染与 SwiftUI 预览注入样例状态(发布路径不受影响)。
    func injectPreviewState(_ state: EngineState) {
        self.state = state
    }

    /// 仅供离屏渲染注入反馈横幅(保存成功 / 钥匙串失败)。
    func injectCredentialNotice(_ notice: CredentialNotice?, for provider: Provider) {
        credentialNotices[provider] = notice
    }
    #endif

    // MARK: - 生命周期

    func start() {
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        await apply(await engine.start())
        presenter.requestAuthorization()
        applyLoginItemDefault()
        guideFirstRunIfNeeded()
        await refreshAll()
        startPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = Date()
                let deadline = await self.engine.nextRefreshAt
                let delay = max(1, (deadline ?? now).timeIntervalSince(now))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
                // 睡眠唤醒 / 手动刷新过后重算:不到点就跳回重算,不提前打请求。
                if await self.engine.shouldRefresh(at: Date()) {
                    await self.refreshAll()
                }
            }
        }
    }

    // MARK: - 刷新

    func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await apply(await engine.refreshAll())
        isRefreshing = false
    }

    func refresh(_ provider: Provider) {
        guard refreshingProvider != provider else { return }
        refreshingProvider = provider
        Task {
            let events = await engine.refresh(provider)
            refreshingProvider = nil
            await apply(events)
        }
    }

    /// popover 打开:重置横幅关闭状态 + 立即触发一次刷新(先显缓存,再原位更新)。
    func popoverOpened() {
        bannerDismissed = false
        Task { await refreshAll() }
    }

    private func apply(_ events: [EngineEvent]) async {
        state = await engine.state
        for event in events {
            switch event {
            case .usageCritical(let alert):
                presenter.post(usageCritical: alert)
            case .credentialInvalid(let provider):
                presenter.post(credentialInvalid: provider)
            case .snapshotUpdated, .usageRecovered, .credentialRestored, .loadFailed, .loadRecovered:
                break
            }
        }
    }

    // MARK: - 通知直达

    private func handleNotificationRoute(_ route: NotificationPresenter.Route) {
        switch route {
        case .usage(let provider):
            // MenuBarExtra 无法以程序方式展开 popover(该场景无 API):
            // 这里把焦点预设为该家并激活 App,下一次点开 popover 即直达该卡片。
            focusProvider = provider
            NSApp.activate(ignoringOtherApps: true)
        case .credential(let provider):
            openSettings(selecting: .provider(provider), fromCredentialAlert: true)
        }
    }

    // MARK: - 凭据

    /// 保存成功返回 true(供设置界面决定是否清空输入框)。
    @discardableResult
    func saveCredential(_ value: String, for provider: Provider) -> Bool {
        switch CredentialEditing.save(value, to: credentials, for: provider) {
        case .saved:
            credentialNotices[provider] = .saved
            notice = nil
            refresh(provider)
            return true
        case .rejectedEmpty:
            credentialNotices[provider] = .error("请先粘贴凭据内容")
            return false
        case .failed(let message):
            credentialNotices[provider] = .error(message)
            return false
        }
    }

    func clearCredential(for provider: Provider) {
        if let message = CredentialEditing.clear(provider, in: credentials) {
            credentialNotices[provider] = .error(message)
            return
        }
        credentialNotices[provider] = nil
        Task { await apply(await engine.credentialCleared(provider)) }
    }

    func dismissCredentialNotice(for provider: Provider) {
        credentialNotices[provider] = nil
    }

    // MARK: - 设置窗口

    func openSettings(selecting selection: SettingsSelection, fromCredentialAlert: Bool = false) {
        requestOpenSettings?(selection, fromCredentialAlert)
    }

    // MARK: - 登录自启

    func setLoginItem(enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginItemEnabled = LoginItem.isEnabled
            defaults.set(true, forKey: DefaultsKey.loginItemPreferenceKnown)
            if loginItemEnabled != enabled {
                notice = Notice(kind: .error, text: "登录自启设置未生效,请检查 ~/Library/LaunchAgents 权限。")
            }
        } catch {
            notice = Notice(kind: .error, text: "无法更新登录自启:\(error.localizedDescription)")
        }
    }

    /// 默认开启;一旦用户改过开关,不再自动改写。
    /// 裸可执行文件(未打包成 .app)没有稳定的登录项身份,不做自动安装。
    private func applyLoginItemDefault() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        guard !defaults.bool(forKey: DefaultsKey.loginItemPreferenceKnown) else { return }
        defaults.set(true, forKey: DefaultsKey.loginItemPreferenceKnown)
        if !LoginItem.isEnabled {
            try? LoginItem.setEnabled(true)
        }
        loginItemEnabled = LoginItem.isEnabled
    }

    // MARK: - 首次启动引导

    private func guideFirstRunIfNeeded() {
        guard !defaults.bool(forKey: DefaultsKey.didGuide) else { return }
        defaults.set(true, forKey: DefaultsKey.didGuide)
        // 读取异常时状态未知:不误判为「未配置」,不弹引导。
        guard state.credentialReadFailures.isEmpty, !state.hasAnyCredential else { return }
        // MenuBarExtra 的 popover 不能以程序方式展开,引导落点改为设置窗口(凭据维护面)。
        openSettings(selecting: .general)
    }

    // MARK: - 退出

    func quit() {
        NSApplication.shared.terminate(nil)
    }
}
