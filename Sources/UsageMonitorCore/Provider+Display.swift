import Foundation

extension Provider {
    /// 界面与通知文案中的显示名。
    public var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi for Coding"
        case .glm: return "GLM Coding Plan"
        }
    }

    /// 官方控制台用量页(登录后可见),「控制台 ↗」链接目标。
    /// 来源:`docs/research/console-urls.md`。
    public var consoleURL: URL {
        switch self {
        case .deepseek: return URL(string: "https://platform.deepseek.com/usage")!
        case .kimi: return URL(string: "https://www.kimi.com/code/console")!
        case .glm: return URL(string: "https://bigmodel.cn/coding-plan/personal/overview")!
        }
    }
}
