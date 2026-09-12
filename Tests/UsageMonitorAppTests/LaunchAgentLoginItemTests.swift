import Foundation
import Testing
@testable import UsageMonitor

/// LaunchAgent 适配器最小冒烟:真实文件系统 + 隔离目录与冒烟专用 label,launchctl 以录制件替身
/// (不触碰用户会话的 launchd,与 Keychain 冒烟「独立 service」同一隔离思路)。
/// 策略逻辑(回读校验、默认开启)在 UsageMonitorCoreTests,不在此重测。
@Suite("LaunchAgent 适配器:plist 写删 + launchctl 序列(隔离)")
struct LaunchAgentLoginItemTests {
    private struct Harness {
        let item: LaunchAgentLoginItem
        let directory: URL
        let launchctl: RecordingLaunchctl

        init() throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("login-item-smoke-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let launchctl = RecordingLaunchctl()
            self.directory = directory
            self.launchctl = launchctl
            self.item = LaunchAgentLoginItem(
                label: "com.nicholasli.usagemonitor.smoke.\(UUID().uuidString)",
                directory: directory,
                executablePath: "/Applications/Usage Monitor.app/Contents/MacOS/UsageMonitor",
                runLaunchctl: launchctl.run
            )
        }

        func plistDictionary() throws -> [String: Any] {
            let data = try Data(contentsOf: item.plistURL)
            guard let dictionary = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any] else {
                throw StubError("plist 顶层不是 dict")
            }
            return dictionary
        }
    }

    struct StubError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    @Test("开启:plist 落盘,Label/RunAtLoad/ProgramArguments 正确指向可执行文件")
    func enableWritesPlistPointingAtExecutable() throws {
        let harness = try Harness()
        let item = harness.item

        try item.setEnabled(true)

        #expect(item.isEnabled)
        let plist = try harness.plistDictionary()
        #expect(plist["Label"] as? String == item.label)
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["ProgramArguments"] as? [String] == ["/Applications/Usage Monitor.app/Contents/MacOS/UsageMonitor"])
    }

    @Test("开启:先 bootout 旧实例再 bootstrap 新 plist(bootstrap 失败回落 load)")
    func enableBootstrapsImmediately() throws {
        let harness = try Harness()
        try harness.item.setEnabled(true)

        let uid = String(getuid())
        let calls = harness.launchctl.calls.map { $0.joined(separator: " ") }
        #expect(calls.contains("bootout gui/\(uid)/\(harness.item.label)"))
        #expect(calls.contains("bootstrap gui/\(uid) \(harness.item.plistURL.path)"))
        #expect(!calls.contains { $0.contains("load -w") })
    }

    @Test("开启:bootstrap 失败时回落 load -w(老语法兜底)")
    func enableFallsBackToLoadWhenBootstrapFails() throws {
        let harness = try Harness()
        harness.launchctl.failSubcommand("bootstrap")

        try harness.item.setEnabled(true)

        // 回读校验只看 plist 落盘事实:launchctl 兜底路径不影响「已开启」。
        #expect(harness.item.isEnabled)
        let calls = harness.launchctl.calls.map { $0.joined(separator: " ") }
        #expect(calls.contains("load -w \(harness.item.plistURL.path)"))
    }

    @Test("关闭:bootout/unload 后删 plist;再关一次不报错(条目不存在不视为错误)")
    func disableRemovesPlistAndIsIdempotent() throws {
        let harness = try Harness()
        try harness.item.setEnabled(true)

        try harness.item.setEnabled(false)

        #expect(!harness.item.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: harness.item.plistURL.path))
        let uid = String(getuid())
        let calls = harness.launchctl.calls.map { $0.joined(separator: " ") }
        #expect(calls.contains("bootout gui/\(uid)/\(harness.item.label)"))
        #expect(calls.contains("unload -w \(harness.item.plistURL.path)"))

        // 幂等:已关闭时再关不抛错。
        try harness.item.setEnabled(false)
        #expect(!harness.item.isEnabled)
    }

    @Test("开 → 关 → 开 round-trip:plist 内容一致")
    func toggleRoundTrip() throws {
        let harness = try Harness()
        try harness.item.setEnabled(true)
        try harness.item.setEnabled(false)
        try harness.item.setEnabled(true)

        #expect(harness.item.isEnabled)
        let plist = try harness.plistDictionary()
        #expect(plist["Label"] as? String == harness.item.label)
        #expect(plist["RunAtLoad"] as? Bool == true)
    }

    @Test("关闭时删文件失败 → 抛错(由策略层转为失败文案)")
    func disableThrowsWhenRemovalFails() throws {
        let harness = try Harness()
        try harness.item.setEnabled(true)
        // 制造删除失败:父目录收归只读,removeItem 无权限。
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.directory.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: harness.directory.path)

        #expect(throws: (any Error).self) { try harness.item.setEnabled(false) }
    }
}

// MARK: - 录制件

/// launchctl 替身:记录调用序列;可指定首参数(子命令)注入非零退出码。
/// 返回值与真实 launchctl 的调用形状一致(status + 输出文本)。
final class RecordingLaunchctl: @unchecked Sendable {
    private let lock = NSLock()
    private var callsStorage: [[String]] = []
    private var failingSubcommands: [String] = []

    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return callsStorage
    }

    /// 以该子命令(如 "bootstrap")开头的调用返回非零退出码。
    func failSubcommand(_ subcommand: String) {
        lock.lock()
        defer { lock.unlock() }
        failingSubcommands.append(subcommand)
    }

    func run(_ arguments: [String]) -> LaunchAgentLoginItem.LaunchctlResult {
        lock.lock()
        defer { lock.unlock() }
        callsStorage.append(arguments)
        let failed = failingSubcommands.contains { arguments.first == $0 }
        return LaunchAgentLoginItem.LaunchctlResult(status: failed ? 1 : 0, output: "")
    }
}
