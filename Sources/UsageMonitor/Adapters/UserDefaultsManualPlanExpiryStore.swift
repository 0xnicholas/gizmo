import Foundation
import UsageMonitorCore

/// 手动到期声明的 UserDefaults 存储(#58):每 provider 一条 Date(标记时刻)。
///
/// 声明是**用户表态**(与「登录自启已表态」同类):重启后仍在,故必须落盘;
/// 不进快照缓存(那是 provider 数据)、不进 raw。不是端口(不新增协议)——
/// 只是把键名与读写的合法性收在一处,便于测试。
struct UserDefaultsManualPlanExpiryStore {
    /// 每 provider 一条:`manualPlanExpiry.<provider>`(值 = 标记时刻)。
    static let keyPrefix = "manualPlanExpiry."

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// 读:非法存储值(类型不符)按「无声明」处理——不误报已标记;判定在 Core。
    func declaration(for provider: Provider) -> ManualPlanExpiry? {
        ManualPlanExpiryEditing.declaration(fromStored: defaults.object(forKey: Self.keyPrefix + provider.rawValue))
    }

    /// 全部已声明的家:引擎构造时注入(重启后仍生效,首个 state 就带它们)。
    func all() -> [Provider: ManualPlanExpiry] {
        var declarations: [Provider: ManualPlanExpiry] = [:]
        for provider in Provider.allCases {
            if let declaration = declaration(for: provider) {
                declarations[provider] = declaration
            }
        }
        return declarations
    }

    /// 写:标记落盘 markedAt;取消移除条目(nil = 无声明)。
    func save(_ declaration: ManualPlanExpiry?, for provider: Provider) {
        let key = Self.keyPrefix + provider.rawValue
        guard let declaration else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(declaration.markedAt, forKey: key)
    }
}
