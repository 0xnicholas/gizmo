import Foundation
import UsageMonitorCore

/// 登录自启适配器:用户级 LaunchAgent(`~/Library/LaunchAgents/<label>.plist`,RunAtLoad,
/// 指向可执行文件),写/删 plist 并 `launchctl` 即时生效(SMAppService 迁移留待正式分发)。
///
/// label/目录/可执行路径/launchctl 均可注入:测试用隔离目录 + 录制件替身,
/// 冒烟(`--smoke-login-item`)用真实 launchctl + 冒烟专用 label。
struct LaunchAgentLoginItem: LoginItemControlling {
    /// 生产 label = bundle id(规格口径 `<bundle-id>.plist`);SwiftPM 裸可执行构建无 bundle id,
    /// 回落固定 label(打包后 bundle id 应与其一致,否则以 bundle id 为准)。
    static let productionLabel = "com.nicholasli.usagemonitor"

    /// launchctl 调用结果:状态码 + 合并后的输出(冒烟打印用)。
    struct LaunchctlResult: Sendable {
        var status: Int32
        var output: String
    }

    let label: String
    let directory: URL
    let executablePath: String
    let runLaunchctl: ([String]) -> LaunchctlResult

    init(
        label: String = Bundle.main.bundleIdentifier ?? LaunchAgentLoginItem.productionLabel,
        directory: URL? = nil,
        executablePath: String? = nil,
        runLaunchctl: @escaping ([String]) -> LaunchctlResult = LaunchAgentLoginItem.launchctl
    ) {
        self.label = label
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        self.executablePath = executablePath ?? Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
        self.runLaunchctl = runLaunchctl
    }

    var plistURL: URL {
        directory.appendingPathComponent("\(label).plist")
    }

    /// 当前用户会话域内的服务标识(launchctl bootout/bootstrap/print 共用)。
    var sessionTarget: String {
        "gui/\(getuid())/\(label)"
    }

    var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            try uninstall()
        }
    }

    private func install() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 经 PropertyListSerialization 落盘:路径含特殊字符也能得到合法 XML 转义。
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)

        // 已加载时先卸载,避免 bootstrap 报「service already loaded」。
        _ = runLaunchctl(["bootout", sessionTarget])
        if runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path]).status != 0 {
            // 老语法兜底(某些环境下 bootstrap 对未签名 plist 更严格)。
            // 双失败也不拖累开关:持久事实是 plist 文件(下次登录由 launchd 扫描目录拉起),
            // bootstrap 只影响当前会话的即时生效;回读以文件为准。
            _ = runLaunchctl(["load", "-w", plistURL.path])
        }
    }

    private func uninstall() throws {
        _ = runLaunchctl(["bootout", sessionTarget])
        _ = runLaunchctl(["unload", "-w", plistURL.path])
        // 条目不存在不视为错误(幂等);存在却删不掉 → 抛错,由策略层转为失败文案。
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    /// 真实 launchctl:合并 stdout/stderr(与系统行为一致,失败信息走 stderr)。
    @discardableResult
    static func launchctl(_ arguments: [String]) -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return LaunchctlResult(status: -1, output: "无法启动 launchctl:\(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return LaunchctlResult(status: process.terminationStatus, output: output)
    }
}
