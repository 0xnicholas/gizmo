import Foundation

/// 登录自启适配器:用户级 LaunchAgent(`~/Library/LaunchAgents/<bundle-id>.plist`,RunAtLoad),
/// 开关写/删 plist 并 `launchctl` 即时生效(SMAppService 迁移留待正式分发)。
enum LoginItem {
    static let label = "com.nicholasli.usagemonitor"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// 可执行文件路径:优先 bundle 内可执行文件,否则当前进程路径。
    static var executablePath: String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? ""
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try install()
        } else {
            uninstall()
        }
    }

    private static func install() throws {
        let directory = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try plistContents().write(to: plistURL, atomically: true, encoding: .utf8)

        let uid = getuid()
        // 已加载时先卸载,避免 bootstrap 报「service already loaded」。
        _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        if runLaunchctl(["bootstrap", "gui/\(uid)", plistURL.path]) != 0 {
            // 老语法兜底(某些环境下 bootstrap 对未签名 plist 更严格)。
            _ = runLaunchctl(["load", "-w", plistURL.path])
        }
    }

    private static func uninstall() {
        let uid = getuid()
        _ = runLaunchctl(["bootout", "gui/\(uid)/\(label)"])
        _ = runLaunchctl(["unload", "-w", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
    }

    private static func plistContents() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>ProcessType</key>
            <string>Interactive</string>
        </dict>
        </plist>
        """
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
