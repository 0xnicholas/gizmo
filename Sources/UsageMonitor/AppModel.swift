import AppKit
import Combine
import SwiftUI
import UserNotifications
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
    /// popover 是否可见(通知点击直达时判断要不要展开,避免把已开的关掉)。
    /// 若系统来路导致 onDisappear 未触发而状态滞留 true,通知点击退化为仅预设焦点——
    /// 与「尽力展开、失败降级」的设计一致,不影响其余功能。
    @Published private(set) var isPopoverVisible = false
    @Published var settingsSelection: SettingsSelection = .general
    @Published var settingsArrivalBanner = false
    @Published private(set) var credentialNotices: [Provider: CredentialNotice] = [:]
    /// 凭据窗格的粘贴草稿:只存在于进程内存;保存/清除成功即消费,窗口真关闭时清空。
    /// 放在 AppModel(而非视图 @State)是为了让窗口关闭拦截点(NSWindowDelegate)能看见「有未保存内容」。
    @Published private(set) var credentialDrafts: [Provider: String] = [:]
    @Published var notice: Notice?
    @Published private(set) var loginItemEnabled: Bool
    /// 设置窗口「通用」展示的通知授权状态(nil = 尚未查到)。
    /// UNAuthorizationStatus 属 UserNotifications,不进 UsageMonitorCore。
    @Published private(set) var notificationAuthorization: UNAuthorizationStatus?

    /// 由 AppDelegate 注入:打开设置窗口(选中某家 / 带「正在更新凭据」横幅)。
    var requestOpenSettings: ((SettingsSelection, Bool) -> Void)?
    /// 由 AppDelegate 注入:设置窗口「完成」关闭按钮。
    var requestCloseSettings: (() -> Void)?

    private let engine: UsageEngine
    private let credentials: any CredentialStore
    private let loginItem: any LoginItemControlling
    private let presenter = NotificationPresenter()
    private let defaults: UserDefaults
    private var pollTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        credentials: any CredentialStore = KeychainCredentialStore(),
        loginItem: any LoginItemControlling = LaunchAgentLoginItem(),
        thresholds: Thresholds = Thresholds()
    ) {
        self.defaults = defaults
        self.credentials = credentials
        self.loginItem = loginItem
        self.loginItemEnabled = loginItem.isEnabled
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

    /// 仅供离屏渲染注入通知授权状态(通用页通知段的三种文案);注入后刷新让位。
    func injectPreviewNotificationAuthorization(_ status: UNAuthorizationStatus?) {
        notificationAuthorization = status
        previewNotificationAuthorizationFrozen = status != nil
    }

    private var previewNotificationAuthorizationFrozen = false

    /// 仅供离屏渲染注入登录开关两态(通用页);渲染路径不跑 bootstrap,不会回读本机 plist。
    func injectPreviewLoginItemEnabled(_ enabled: Bool) {
        loginItemEnabled = enabled
    }
    #endif

    // MARK: - 生命周期

    func start() {
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        await apply(await engine.start())
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
        isPopoverVisible = true
        bannerDismissed = false
        Task { await refreshAll() }
    }

    func popoverClosed() {
        isPopoverVisible = false
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
            // 聚焦该家并尽力展开 popover(MenuBarExtra 无公开 API,尽力模拟点击;
            // 失败则保持预设焦点,下一次点开 popover 即直达该卡片)。
            focusProvider = provider
            NSApp.activate(ignoringOtherApps: true)
            if !isPopoverVisible {
                MenuBarExtraOpener.openPopover()
            }
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
            credentialDrafts[provider] = nil
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
        credentialDrafts[provider] = nil
        Task { await apply(await engine.credentialCleared(provider)) }
    }

    // MARK: - 凭据草稿

    /// 是否存在未保存草稿(策略见 CredentialDraftEditing):窗口关闭前是否需要确认。
    var hasUnsavedCredentialDraft: Bool {
        CredentialDraftEditing.hasUnsavedDraft(credentialDrafts)
    }

    /// 窗格输入框绑定入口;非空输入时顺手清掉旧反馈(错误横幅/成功提示不驻留)。
    func updateCredentialDraft(_ value: String, for provider: Provider) {
        credentialDrafts[provider] = value
        if !value.isEmpty {
            dismissCredentialNotice(for: provider)
        }
    }

    /// 窗口真关闭时调用:草稿即弃,凭据文本不驻留内存。
    func discardCredentialDrafts() {
        guard !credentialDrafts.isEmpty else { return }
        credentialDrafts = [:]
    }

    func dismissCredentialNotice(for provider: Provider) {
        credentialNotices[provider] = nil
    }

    // MARK: - 通知

    /// 「通用」页展示授权状态;拒绝后的手动恢复说明也在那里。
    func refreshNotificationAuthorization() {
        #if DEBUG
        guard !previewNotificationAuthorizationFrozen else { return }  // 离屏渲染注入值优先
        #endif
        Task { @MainActor in
            notificationAuthorization = await presenter.authorizationStatus()
        }
    }

    // MARK: - 设置窗口

    func openSettings(selecting selection: SettingsSelection, fromCredentialAlert: Bool = false) {
        requestOpenSettings?(selection, fromCredentialAlert)
    }

    // MARK: - 登录自启

    /// 开关即时生效;回读落盘事实驱动 UI(失败时开关弹回真实状态)。
    /// 成功拨动即视为用户已表态,默认逻辑此后不再自动改写。
    func setLoginItem(enabled: Bool) {
        let outcome = LoginItemEditing.setEnabled(enabled, in: loginItem)
        loginItemEnabled = loginItem.isEnabled
        switch outcome {
        case .applied:
            defaults.set(true, forKey: DefaultsKey.loginItemPreferenceKnown)
        case .failed(let message):
            notice = Notice(kind: .error, text: message)
        }
    }

    /// 首启默认开启(仅打包身份、仅一次);策略语义见 LoginItemEditing。
    private func applyLoginItemDefault() {
        let outcome = LoginItemEditing.applyDefault(
            hasBundleIdentity: Bundle.main.bundleIdentifier != nil,
            preferenceKnown: defaults.bool(forKey: DefaultsKey.loginItemPreferenceKnown),
            in: loginItem
        )
        if outcome == .applied {
            defaults.set(true, forKey: DefaultsKey.loginItemPreferenceKnown)
        }
        loginItemEnabled = loginItem.isEnabled
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
