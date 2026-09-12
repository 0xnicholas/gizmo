import Foundation

/// 凭据写入策略:保存前 trim 首尾空白、全空白拒绝、存储失败转成可展示文案。
///
/// 设置面只消费结果(保存成功 / 拒绝 / 失败文案),不直接碰存储的错误类型;
/// 错误细节(如系统钥匙串错误码)由 `CredentialStore` 适配器以 `LocalizedError` 提供。
public enum CredentialEditing {
    public enum Outcome: Equatable, Sendable {
        /// 已写入存储;存储收到的是 trim 后的值。
        case saved
        /// 输入全为空白,未触碰存储。
        case rejectedEmpty
        /// 写入失败,附可展示的错误文案(如钥匙串错误码)。
        case failed(String)
    }

    /// 保存:trim 后为空则拒绝;存储抛错时返回失败文案(存储内容不变)。
    public static func save(_ value: String, to store: any CredentialStore, for provider: Provider) -> Outcome {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .rejectedEmpty }
        do {
            try store.save(trimmed, for: provider)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 清除:返回 nil 表示已清除,否则为可展示的错误文案(存储内容未变)。
    public static func clear(_ provider: Provider, in store: any CredentialStore) -> String? {
        do {
            try store.delete(for: provider)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
