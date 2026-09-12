import Foundation
import UserNotifications
import UsageMonitorCore

/// 本地通知适配器:两类通知走同一系统通道,限流(24h 静默)已在引擎内判定。
///
/// 通知需要 .app bundle(Info.plist 的 CFBundleIdentifier);以裸可执行文件运行时
/// UNUserNotificationCenter 不可用,此处静默降级,不影响其余功能。
/// userInfo 键(非隔离常量,供 nonisolated 的 delegate 回调读取)。
private enum NotificationKey {
    static let provider = "provider"
    static let kind = "kind"
}

/// 点击通知的直达语义:临界 → popover 聚焦该家;凭据失效 → 设置窗口选中该家。
enum NotificationRoute: Equatable, Sendable {
    case usage(Provider)
    case credential(Provider)
}

/// 通知同屏不打扰(C4,#42)的呈现决策(纯逻辑,单测直测;willPresent 消费):
/// popover 或设置窗口正可见时不横幅、不响(返回空 options,通知仍投递进通知中心),
/// 不可见时维持横幅 + 声音。消灭「正看着卡片又弹同一条通知」的同屏双通道打扰。
enum NotificationPresentationDecision {
    /// 任一呈现面(popover / 设置窗口)可见即抑制。
    static func isSuppressed(popoverVisible: Bool, settingsVisible: Bool) -> Bool {
        popoverVisible || settingsVisible
    }

    /// 抑制 → 空 options(静默投递:仅通知中心,不横幅不响);否则横幅 + 声音。
    static func options(suppress: Bool) -> UNNotificationPresentationOptions {
        suppress ? [] : [.banner, .sound]
    }
}

@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    typealias Route = NotificationRoute

    var onOpen: ((Route) -> Void)?

    /// 由 AppModel 注入(与 onOpen 同路):popover 或设置窗口是否可见。
    /// willPresent 据此静默投递(C4)。若 popover 的 onDisappear 未触发而状态滞留 true,
    /// 通知退化为持续静默——与 isPopoverVisible 既有注释的「尽力降级」口径一致。
    var isAnySurfaceVisible: (@MainActor () -> Bool)?

    private let isAvailable: Bool

    override init() {
        self.isAvailable = Bundle.main.bundleIdentifier != nil
        super.init()
        if isAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    /// 供设置窗口展示当前授权状态(拒绝后的手动恢复说明用)。
    func authorizationStatus() async -> UNAuthorizationStatus {
        guard isAvailable else { return .notDetermined }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    func post(usageCritical alert: UsageAlert) {
        post(
            identifier: alert.notificationIdentifier,
            title: "用量临界",
            body: alert.text,
            route: .usage(alert.provider)
        )
    }

    func post(credentialInvalid provider: Provider) {
        post(
            identifier: "credential-invalid-\(provider.rawValue)",
            title: "凭据失效",
            body: provider.credentialAlertText,
            route: .credential(provider)
        )
    }

    #if DEBUG
    /// DEBUG 验收入口(C4,#42):发一条可区分的测试临界通知;文案与点击路由复用生产路径
    /// (UsageAlert.text / notificationIdentifier + 序号后缀,通知中心可累积对照)。
    /// 仅供 --debug-test-notifications 使用。
    func debugPostTestCritical(sequence: Int) {
        let alert = UsageAlert(
            provider: .glm,
            basis: .window(label: "7 天窗", remaining: 42, limit: 1000, unit: "积分", percent: 4)
        )
        post(
            identifier: "\(alert.notificationIdentifier)-debug-\(sequence)",
            title: "用量临界(测试 \(sequence))",
            body: alert.text,
            route: .usage(alert.provider)
        )
    }
    #endif

    private func post(identifier: String, title: String, body: String, route: Route) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            NotificationKey.provider: route.provider.rawValue,
            NotificationKey.kind: route.kind,
        ]
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        // 首次需要时请求授权:notDetermined → 现场弹系统询问,同意才投递本条;
        // 已拒绝 → 静默跳过(恢复入口在设置窗口说明里)。
        // add 线程安全,回调队列直接投递即可。
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                center.add(request)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            default:
                break
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // C4 同屏不打扰:用户正看着 popover / 设置窗口时不横幅不响(仍进通知中心);
        // 不可见时维持横幅 + 声音(菜单栏 App 也可能处于「活跃」,仍要展示)。
        // 注:willPresent 只在 app 前台时被调——后台时系统默认横幅本就正确(用户注意力
        // 在别处),设置窗口留在屏上但 app 已切后台的情形因此不受此闭包控制,属平台边界。
        NotificationPresentationDecision.options(suppress: await isAnySurfaceVisibleNow())
    }

    /// 回到主 actor 读取注入的可见性闭包(isAnySurfaceVisible 存储属性隔离在主 actor)。
    @MainActor
    private func isAnySurfaceVisibleNow() -> Bool {
        isAnySurfaceVisible?() ?? false
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let provider = (userInfo[NotificationKey.provider] as? String).flatMap(Provider.init(rawValue:))
        let kind = userInfo[NotificationKey.kind] as? String
        guard let provider, let kind else { return }
        let route: Route?
        switch kind {
        case "usage": route = .usage(provider)
        case "credential": route = .credential(provider)
        default: route = nil
        }
        guard let route else { return }
        await deliver(route)
    }

    /// 回到主 actor 交给 AppModel 处理直达语义。
    private func deliver(_ route: Route) {
        onOpen?(route)
    }
}

private extension NotificationPresenter.Route {
    var provider: Provider {
        switch self {
        case .usage(let provider), .credential(let provider): return provider
        }
    }

    var kind: String {
        switch self {
        case .usage: return "usage"
        case .credential: return "credential"
        }
    }
}
