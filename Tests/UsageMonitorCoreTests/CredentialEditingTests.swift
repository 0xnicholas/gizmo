import Foundation
import Testing
@testable import UsageMonitorCore

/// 凭据写入策略(设置窗口「保存到钥匙串」「清除凭据」背后的行为):
/// trim、空值拒绝、存储失败转可展示文案。
@Suite("凭据写入:trim / 空值 / 失败路径")
struct CredentialEditingTests {
    /// 与 Keychain 适配器的 LocalizedError 同形:文案带错误码、不含凭据原文。
    private struct StubFailure: LocalizedError {
        let code: Int
        var errorDescription: String? { "钥匙串操作失败(错误码 \(code))。请检查钥匙串是否已锁定。" }
    }

    @Test("保存自动去除首尾空白:存储收到 trim 后的值")
    func saveTrimsWhitespace() throws {
        let store = FakeCredentialStore()

        let outcome = CredentialEditing.save(" \n sk-abc123 \t ", to: store, for: .deepseek)

        #expect(outcome == .saved)
        #expect(try store.credential(for: .deepseek) == "sk-abc123")
    }

    @Test("全空白输入不触碰存储,返回 rejectedEmpty")
    func saveRejectsBlankValue() throws {
        let store = FakeCredentialStore()

        #expect(CredentialEditing.save("", to: store, for: .kimi) == .rejectedEmpty)
        #expect(CredentialEditing.save(" \n\t ", to: store, for: .kimi) == .rejectedEmpty)
        #expect(try store.credential(for: .kimi) == nil)
    }

    @Test("写入失败:返回 failed 且文案带错误码;存储保持原值")
    func saveFailureKeepsExistingValue() throws {
        let store = FakeCredentialStore(values: [.glm: "old-key"])
        store.failWrites(with: StubFailure(code: -34018))

        let outcome = CredentialEditing.save("new-key", to: store, for: .glm)

        #expect(outcome == .failed("钥匙串操作失败(错误码 -34018)。请检查钥匙串是否已锁定。"))
        #expect(try store.credential(for: .glm) == "old-key")
    }

    @Test("覆盖保存:旧值被新值替换")
    func saveOverwritesExistingValue() throws {
        let store = FakeCredentialStore(values: [.kimi: "old-value"])

        #expect(CredentialEditing.save("new-value", to: store, for: .kimi) == .saved)
        #expect(try store.credential(for: .kimi) == "new-value")
    }

    @Test("清除成功返回 nil 并清空;清除失败返回文案且内容不变")
    func clearSucceedsAndFails() throws {
        let store = FakeCredentialStore(values: [.deepseek: "sk-abc"])
        #expect(CredentialEditing.clear(.deepseek, in: store) == nil)
        #expect(try store.credential(for: .deepseek) == nil)

        let failing = FakeCredentialStore(values: [.deepseek: "sk-abc"])
        failing.failWrites(with: StubFailure(code: -25308))
        let message = CredentialEditing.clear(.deepseek, in: failing)
        #expect(message == "钥匙串操作失败(错误码 -25308)。请检查钥匙串是否已锁定。")
        #expect(try failing.credential(for: .deepseek) == "sk-abc")
    }
}
