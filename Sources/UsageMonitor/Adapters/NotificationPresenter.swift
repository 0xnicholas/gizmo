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
enum NotificationRoute: Equatable {
    case usage(Provider)
    case credential(Provider)
}

@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    typealias Route = NotificationRoute

    var onOpen: ((Route) -> Void)?

    private let isAvailable: Bool

    override init() {
        self.isAvailable = Bundle.main.bundleIdentifier != nil
        super.init()
        if isAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(usageCritical alert: UsageAlert) {
        post(
            identifier: "usage-critical-\(alert.provider.rawValue)",
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

    private func post(identifier: String, title: String, body: String, route: Route) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            NotificationKey.provider: route.provider.rawValue,
            NotificationKey.kind: route.kind,
        ]
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // 菜单栏 App 也可能处于「活跃」,仍要展示横幅。
        [.banner, .sound]
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
