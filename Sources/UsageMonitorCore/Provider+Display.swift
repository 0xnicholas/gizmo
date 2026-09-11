import Foundation

extension Provider {
    /// 界面展示顺序:GLM / Kimi / DeepSeek(用户故事 20 的标签页顺序)。
    /// 与 `allCases` 分开,后者是枚举声明顺序,供引擎与文件编码保持确定性。
    public static let displayOrder: [Provider] = [.glm, .kimi, .deepseek]

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
