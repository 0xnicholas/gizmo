import Foundation
import Security
import Testing
import UsageMonitorCore
@testable import UsageMonitor

/// Keychain 适配器最小冒烟:真实 Security 框架 + 独立 service(不碰生产凭据)。
///
/// 只验证端口契约与实现决策——GenericPassword、service/account、读回 trim 与全空白视同缺失、
/// 覆盖写、清除;策略逻辑不在此重测。
@Suite("Keychain 适配器:真实钥匙串冒烟", .serialized)
struct KeychainCredentialStoreTests {
    private static func uniqueService() -> String {
        "com.nicholasli.usagemonitor.credentials.smoke.\(UUID().uuidString)"
    }

    @Test("保存/读取 round-trip:自动 trim;account = provider 键名")
    func roundTripTrimsAndStoresAccount() throws {
        let service = Self.uniqueService()
        let store = KeychainCredentialStore(service: service)
        defer { for provider in Provider.allCases { try? store.delete(for: provider) } }

        try store.save("  sk-smoke-123\n", for: .deepseek)
        #expect(try store.credential(for: .deepseek) == "sk-smoke-123")
        #expect(try store.credential(for: .kimi) == nil)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
        ]
        var item: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess)
        let attributes = try #require(item as? [String: Any])
        #expect(attributes[kSecAttrService as String] as? String == service)
        #expect(attributes[kSecAttrAccount as String] as? String == Provider.deepseek.rawValue)
    }

    @Test("accessible = AfterFirstUnlockThisDeviceOnly:写入后可按该约束检索到")
    func storesAccessibleAttribute() throws {
        let service = Self.uniqueService()
        let store = KeychainCredentialStore(service: service)
        defer { try? store.delete(for: .glm) }

        try store.save("glm-smoke-key", for: .glm)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Provider.glm.rawValue,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess)
    }

    @Test("覆盖保存与清除:清除后读回 nil,重复清除不抛错")
    func overwriteAndDelete() throws {
        let service = Self.uniqueService()
        let store = KeychainCredentialStore(service: service)
        defer { try? store.delete(for: .kimi) }

        try store.save("first-value", for: .kimi)
        try store.save("second-value", for: .kimi)
        #expect(try store.credential(for: .kimi) == "second-value")

        try store.delete(for: .kimi)
        #expect(try store.credential(for: .kimi) == nil)
        try store.delete(for: .kimi)
    }

    @Test("清除后不再命中该 service 下的任何条目")
    func deleteRemovesItem() throws {
        let service = Self.uniqueService()
        let store = KeychainCredentialStore(service: service)
        try store.save("kimi-value", for: .kimi)

        try store.delete(for: .kimi)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        #expect(SecItemCopyMatching(query as CFDictionary, nil) == errSecItemNotFound)
    }

    @Test("全空白值不构成已配置:读回 nil")
    func blankValueReadsAsMissing() throws {
        let service = Self.uniqueService()
        let store = KeychainCredentialStore(service: service)
        defer { try? store.delete(for: .kimi) }

        try store.save("  \n\t ", for: .kimi)

        #expect(try store.credential(for: .kimi) == nil)
    }

    /// 对应人工验证开关 `--simulate-keychain-failure`:写入/清除必失败,读取照常。
    @Test("故障注入存储:写入与清除都得到带错误码的红横幅文案")
    func simulatedFailureStoreProducesBannerMessage() throws {
        let service = Self.uniqueService()
        let base = KeychainCredentialStore(service: service)
        try base.save("kimi-value", for: .kimi)
        defer { try? base.delete(for: .kimi) }
        let store = WriteFailingCredentialStore(base: base)
        let message = "钥匙串操作失败(错误码 -34018)。请检查钥匙串是否已锁定。"

        #expect(CredentialEditing.save("new-value", to: store, for: .kimi) == .failed(message))
        #expect(CredentialEditing.clear(.kimi, in: store) == message)
        // 读取不受影响:人工验证时其余界面仍按已配置展示。
        #expect(try store.credential(for: .kimi) == "kimi-value")
    }
}
