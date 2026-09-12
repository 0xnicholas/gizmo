import Foundation
import Security
import UsageMonitorCore

/// Keychain 适配器:GenericPassword,service = 应用标识,account = provider 键名。
///
/// 红线:凭据值只在进程内存与钥匙串之间流转——不落日志、不进 UserDefaults、不进快照 raw。
struct KeychainCredentialStore: CredentialStore {
    static let service = "com.nicholasli.usagemonitor.credentials"

    /// 测试/冒烟可用独立 service 隔离;生产固定用 `Self.service`。
    private let service: String

    init(service: String = KeychainCredentialStore.service) {
        self.service = service
    }

    enum Failure: LocalizedError, Equatable {
        case unexpectedStatus(OSStatus)
        case corruptedValue

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "钥匙串操作失败(错误码 \(status))。请检查钥匙串是否已锁定。"
            case .corruptedValue:
                return "钥匙串中的凭据无法读取(编码异常),请重新保存。"
            }
        }
    }

    func credential(for provider: Provider) throws -> String? {
        var query = baseQuery(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw Failure.corruptedValue
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    /// 保存(已存在的条目原地更新)。保存前自动去除首尾空白。
    func save(_ value: String, for provider: Provider) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        let query = baseQuery(for: provider)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure.unexpectedStatus(addStatus) }
        default:
            throw Failure.unexpectedStatus(updateStatus)
        }
    }

    func delete(for provider: Provider) throws {
        let status = SecItemDelete(baseQuery(for: provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.unexpectedStatus(status)
        }
    }

    private func baseQuery(for provider: Provider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}

#if DEBUG
/// 开发期故障注入(仅 DEBUG,`--simulate-keychain-failure`):读照常,任何写入/清除都必然失败,
/// 用于人工验证设置窗口的红色失败横幅与「失败不清空输入」行为。
struct WriteFailingCredentialStore: CredentialStore {
    let base: any CredentialStore

    func credential(for provider: Provider) throws -> String? {
        try base.credential(for: provider)
    }

    func save(_ value: String, for provider: Provider) throws {
        throw KeychainCredentialStore.Failure.unexpectedStatus(-34018)
    }

    func delete(for provider: Provider) throws {
        throw KeychainCredentialStore.Failure.unexpectedStatus(-34018)
    }
}
#endif
