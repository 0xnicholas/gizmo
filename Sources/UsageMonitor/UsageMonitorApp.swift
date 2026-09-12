import AppKit
import SwiftUI
import UsageMonitorCore

/// 菜单栏 App:MenuBarExtra(popover)+ 独立设置窗口(由 AppDelegate 以 AppKit 承载,
/// 这样通知点击可以直接把窗口提到最前并选中某家)。
@main
struct UsageMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: appDelegate.model)
        } label: {
            MenuBarLabelView(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel

    override init() {
        model = AppModel(credentials: Self.makeCredentialStore())
        super.init()
    }

    /// DEBUG 下 `--simulate-keychain-failure` 注入「写入必失败、读取照常」,用于人工验证红横幅路径。
    private static func makeCredentialStore() -> any CredentialStore {
        #if DEBUG
        if CommandLine.arguments.contains("--simulate-keychain-failure") {
            return WriteFailingCredentialStore(base: KeychainCredentialStore())
        }
        #endif
        return KeychainCredentialStore()
    }

    private var settingsController: SettingsWindowController?
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // accessory:无 Dock 图标、不占 Cmd-Tab。
        NSApplication.shared.setActivationPolicy(.accessory)

        #if DEBUG
        // 开发期离屏渲染真实视图(--render-previews <目录>),不进入常驻路径。
        if DevPreviewRenderer.runIfRequested() {
            NSApplication.shared.terminate(nil)
            return
        }
        // 真实链路冒烟(--smoke-fetch / --smoke-poll / --smoke-auth / --smoke-outage):跑完即退。
        if SmokeRunner.isRequested {
            Task { @MainActor in
                await SmokeRunner.run()
            }
            return
        }
        #endif

        // 登录自启的 plist 会 RunAtLoad 拉起新实例;已有实例在跑时直接退出。
        guard isOnlyInstance else {
            NSApplication.shared.terminate(nil)
            return
        }

        // 防 App Nap:后台 30 分钟轮询保准点(系统睡眠天然暂停,唤醒后自然恢复)。
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.background, .automaticTerminationDisabled, .suddenTerminationDisabled],
            reason: "用量监视器后台轮询"
        )

        model.requestOpenSettings = { [weak self] selection, fromCredentialAlert in
            self?.showSettings(selection: selection, fromCredentialAlert: fromCredentialAlert)
        }
        model.requestCloseSettings = { [weak self] in
            self?.settingsController?.window?.performClose(nil)
        }
        model.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 设置窗口关闭 ≠ 退出 App。
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
    }

    private var isOnlyInstance: Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return true }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).count <= 1
    }

    func showSettings(selection: AppModel.SettingsSelection, fromCredentialAlert: Bool) {
        model.settingsSelection = selection
        model.settingsArrivalBanner = fromCredentialAlert

        let controller: SettingsWindowController
        if let existing = settingsController {
            controller = existing
        } else {
            controller = SettingsWindowController(model: model)
            settingsController = controller
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

/// 红绿灯标题「用量监视器设置」的独立窗口;关闭即隐藏,再次打开复用同一实例。
/// 所有关闭路径(红点 / Cmd+W /「完成」/ performClose)汇聚在 windowShouldClose:
/// 有未保存凭据草稿时先确认,避免静默丢弃已粘贴内容。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var modelRef: AppModel?

    init(model: AppModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "用量监视器设置"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: SettingsWindowView(model: model))
        window.center()
        super.init(window: window)
        modelRef = model
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    // MARK: - 关闭拦截

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model = modelRef, model.hasUnsavedCredentialDraft else { return true }
        confirmDiscardDrafts(in: sender) { discard in
            guard discard else { return }
            model.discardCredentialDrafts()
            sender.performClose(nil)
        }
        return false
    }

    /// 窗口真关闭(含确认后关闭):草稿即弃,凭据文本不驻留内存。
    func windowWillClose(_ notification: Notification) {
        modelRef?.discardCredentialDrafts()
    }

    /// 未保存草稿确认:默认(回车/继续编辑)保留内容;丢弃是显式 destructive 动作。
    private func confirmDiscardDrafts(in window: NSWindow, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "有未保存的凭据内容"
        alert.informativeText = "窗口里还有已粘贴但未保存的凭据,关闭将丢弃;已保存到钥匙串的内容不受影响。"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "丢弃并关闭")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertSecondButtonReturn)
        }
    }
}
