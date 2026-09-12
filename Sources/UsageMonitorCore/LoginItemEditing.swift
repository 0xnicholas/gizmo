import Foundation

/// 登录自启端口:写/删用户级 LaunchAgent 并即时生效;`isEnabled` 回读落盘事实,
/// 供策略在写后校验「确实生效」。
public protocol LoginItemControlling: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// 登录自启策略:设置开关的回读校验与首启默认开启。与 `CredentialEditing` 同构——
/// 设置面只消费结果(已生效 / 失败文案),不碰适配器的错误类型。
///
/// 语义(#13 决议):
/// - 默认开启:仅打包身份(app bundle)且用户从未表态时执行一次;
///   即使失败也视为已表态,不在后续启动反复重试。
/// - 裸可执行文件(无打包身份)没有稳定的登录项身份,不自动安装、不标记。
/// - 用户一旦成功拨动开关,默认逻辑永不自动改写。
public enum LoginItemEditing {
    /// 开关结果:回读确认生效,或附可展示的失败文案。
    public enum Outcome: Equatable, Sendable {
        /// 已写/删并回读确认。
        case applied
        /// 抛错或写后未生效,附可展示文案。
        case failed(String)
    }

    /// 用户拨动开关:立即写/删并回读校验(「即时生效」的事实检查)。
    /// 成功即视为用户已表态(调用方应记录,默认逻辑此后不再介入)。
    public static func setEnabled(_ enabled: Bool, in item: any LoginItemControlling) -> Outcome {
        do {
            try item.setEnabled(enabled)
        } catch {
            return .failed("无法更新登录自启:\(error.localizedDescription)")
        }
        return item.isEnabled == enabled
            ? .applied
            : .failed("登录自启设置未生效,请检查 ~/Library/LaunchAgents 权限。")
    }

    /// 默认开启的结果:调用方据此决定是否标记「用户已表态」。
    public enum DefaultOutcome: Equatable, Sendable {
        /// 已执行默认开启(无论成败,不再重试)→ 标记已表态。
        case applied
        /// 裸可执行文件:跳过,不标记。
        case skippedNoBundleIdentity
        /// 用户已表态:永不自动改写。
        case skippedAlreadyKnown
    }

    /// 首启默认开启:仅打包身份且从未表态时,确保登录自启处于开启。
    public static func applyDefault(
        hasBundleIdentity: Bool,
        preferenceKnown: Bool,
        in item: any LoginItemControlling
    ) -> DefaultOutcome {
        guard hasBundleIdentity else { return .skippedNoBundleIdentity }
        guard !preferenceKnown else { return .skippedAlreadyKnown }
        if !item.isEnabled {
            try? item.setEnabled(true)
        }
        return .applied
    }
}
