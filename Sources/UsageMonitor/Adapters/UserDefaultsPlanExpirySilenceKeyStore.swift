import Foundation
import UsageMonitorCore

/// 到期提醒静默键的 UserDefaults 适配器(#57):每 provider 一条,值 = Codable 的
/// 两枚「已提醒过的有效期端点」。
///
/// 落盘才能让「同一个有效期只提醒一次」跨重启成立(改系统时间也绕不开——键是端点、
/// 不是时间戳)。值与快照缓存分家:它是通知记账,不是 provider 数据。
/// 读不出/串损坏的条目按「无记录」处理:失效方向偏「可能多提醒一次」,而不是
/// 「静默失效、再也不提醒」。
final class UserDefaultsPlanExpirySilenceKeyStore: PlanExpirySilenceKeyStore, @unchecked Sendable {
    /// 每 provider 一条:`planExpirySilenceKeys.<provider>`。
    static let keyPrefix = "planExpirySilenceKeys."

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> [Provider: PlanExpirySilenceKeys] {
        var keys: [Provider: PlanExpirySilenceKeys] = [:]
        for provider in Provider.allCases {
            guard let data = defaults.data(forKey: Self.keyPrefix + provider.rawValue),
                  let decoded = try? JSONDecoder().decode(PlanExpirySilenceKeys.self, from: data)
            else { continue }
            keys[provider] = decoded
        }
        return keys
    }

    func save(_ keys: [Provider: PlanExpirySilenceKeys]) {
        for provider in Provider.allCases {
            let key = Self.keyPrefix + provider.rawValue
            guard let value = keys[provider], let data = try? JSONEncoder().encode(value) else {
                defaults.removeObject(forKey: key)
                continue
            }
            defaults.set(data, forKey: key)
        }
    }
}
