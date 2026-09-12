import Foundation

/// 凭据草稿的未保存判定:窗口关闭前是否需要确认。
///
/// 「有草稿」的语义与保存一致:trim 后非空才算(手滑粘进纯空白不构成待保存内容)。
/// 草稿值本身仍只存在于进程内存(AppModel),不落任何存储。
public enum CredentialDraftEditing {
    /// 是否存在未保存的凭据草稿(任一 provider 的草稿 trim 后非空)。
    public static func hasUnsavedDraft(_ drafts: [Provider: String]) -> Bool {
        drafts.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
