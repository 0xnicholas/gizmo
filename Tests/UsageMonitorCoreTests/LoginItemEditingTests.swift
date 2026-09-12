import Foundation
import Testing
@testable import UsageMonitorCore

/// 登录自启策略(#22):开关回读校验 + 默认开启(仅一次、仅打包身份)。
/// 与 CredentialEditingTests 同构:策略只依赖 LoginItemControlling 端口,适配器不在此测。
@Suite("LoginItemEditing:开关与默认开启策略")
struct LoginItemEditingTests {
    // MARK: - setEnabled(用户拨动开关)

    @Test("开启成功:写入并回读确认 → applied")
    func setEnabledApplied() {
        let item = FakeLoginItem(enabled: false)
        let outcome = LoginItemEditing.setEnabled(true, in: item)
        #expect(outcome == .applied)
        #expect(item.isEnabled)
    }

    @Test("关闭成功:删除并回读确认 → applied")
    func setDisabledApplied() {
        let item = FakeLoginItem(enabled: true)
        let outcome = LoginItemEditing.setEnabled(false, in: item)
        #expect(outcome == .applied)
        #expect(!item.isEnabled)
    }

    @Test("适配器抛错 → failed 带可展示文案(含底层描述),状态不变")
    func setEnabledThrowsFails() {
        let item = FakeLoginItem(enabled: false)
        item.failSets(with: StubError("目录不可写"))
        let outcome = LoginItemEditing.setEnabled(true, in: item)
        guard case .failed(let message) = outcome else {
            Issue.record("应当失败,实际 \(outcome)")
            return
        }
        #expect(message.contains("无法更新登录自启"))
        #expect(message.contains("目录不可写"))
        #expect(!item.isEnabled)
    }

    @Test("写后未生效(回读不符)→ failed 提示检查 LaunchAgents 权限")
    func setEnabledIneffectiveFails() {
        let item = FakeLoginItem(enabled: false, dropSetEffects: true)
        let outcome = LoginItemEditing.setEnabled(true, in: item)
        guard case .failed(let message) = outcome else {
            Issue.record("应当失败,实际 \(outcome)")
            return
        }
        #expect(message == "登录自启设置未生效,请检查 ~/Library/LaunchAgents 权限。")
        #expect(!item.isEnabled)
    }

    // MARK: - applyDefault(首启默认开启)

    @Test("首启 + 打包身份 + 未表态 → 默认开启")
    func defaultEnablesOnFirstRun() {
        let item = FakeLoginItem(enabled: false)
        let outcome = LoginItemEditing.applyDefault(hasBundleIdentity: true, preferenceKnown: false, in: item)
        #expect(outcome == .applied)
        #expect(item.isEnabled)
    }

    @Test("已开启时默认逻辑不重复写")
    func defaultSkipsWhenAlreadyEnabled() {
        let item = FakeLoginItem(enabled: true)
        let outcome = LoginItemEditing.applyDefault(hasBundleIdentity: true, preferenceKnown: false, in: item)
        #expect(outcome == .applied)
        #expect(item.setCallCount == 0)
    }

    @Test("用户已表态 → 永不自动改写(关了就保持关)")
    func defaultSkipsWhenPreferenceKnown() {
        let item = FakeLoginItem(enabled: false)
        let outcome = LoginItemEditing.applyDefault(hasBundleIdentity: true, preferenceKnown: true, in: item)
        #expect(outcome == .skippedAlreadyKnown)
        #expect(!item.isEnabled)
        #expect(item.setCallCount == 0)
    }

    @Test("裸可执行文件(无打包身份)→ 跳过且不标记已表态")
    func defaultSkipsBareExecutable() {
        let item = FakeLoginItem(enabled: false)
        let outcome = LoginItemEditing.applyDefault(hasBundleIdentity: false, preferenceKnown: false, in: item)
        #expect(outcome == .skippedNoBundleIdentity)
        #expect(!item.isEnabled)
        #expect(item.setCallCount == 0)
    }

    @Test("默认开启失败(如目录损坏)→ 仍视为已表态,下次启动不再重试")
    func defaultDoesNotRetryAfterFailure() {
        let item = FakeLoginItem(enabled: false)
        item.failSets(with: StubError("权限不足"))
        let outcome = LoginItemEditing.applyDefault(hasBundleIdentity: true, preferenceKnown: false, in: item)
        #expect(outcome == .applied)
        #expect(!item.isEnabled)
    }
}

// MARK: - 假件

/// 可注入失败的登录自启假件:记录 setEnabled 次数,支持「写入成功但状态不动」的未生效形态。
final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var enabledStorage: Bool
    private var setErrorStorage: (any Error)?
    /// 构造「写入成功但回读不变」(如 plist 写入被外部拦截后删除)。
    private let dropSetEffects: Bool
    private var setCallCountStorage = 0

    init(enabled: Bool, dropSetEffects: Bool = false) {
        self.enabledStorage = enabled
        self.dropSetEffects = dropSetEffects
    }

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabledStorage
    }

    var setCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return setCallCountStorage
    }

    func failSets(with error: any Error) {
        lock.lock()
        defer { lock.unlock() }
        setErrorStorage = error
    }

    func setEnabled(_ enabled: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        setCallCountStorage += 1
        if let setErrorStorage { throw setErrorStorage }
        if !dropSetEffects { enabledStorage = enabled }
    }
}

struct StubError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
