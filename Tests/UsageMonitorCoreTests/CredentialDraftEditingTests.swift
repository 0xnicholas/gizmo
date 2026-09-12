import Testing
@testable import UsageMonitorCore

/// 草稿未保存判定:与保存的 trim 语义对齐(全空白 ≠ 草稿)。
@Suite("CredentialDraftEditing:未保存草稿判定")
struct CredentialDraftEditingTests {
    @Test("无任何草稿:不需要确认")
    func empty() {
        #expect(!CredentialDraftEditing.hasUnsavedDraft([:]))
    }

    @Test("任一家有非空白草稿:需要确认")
    func nonEmpty() {
        #expect(CredentialDraftEditing.hasUnsavedDraft([.kimi: "token-xyz"]))
        #expect(CredentialDraftEditing.hasUnsavedDraft([.deepseek: "sk-test", .glm: "raw-key"]))
    }

    @Test("全空白草稿视同无草稿:与保存的 trim 语义一致")
    func whitespaceOnly() {
        #expect(!CredentialDraftEditing.hasUnsavedDraft([.kimi: ""]))
        #expect(!CredentialDraftEditing.hasUnsavedDraft([.kimi: "  \n\t "]))
        #expect(!CredentialDraftEditing.hasUnsavedDraft([.kimi: " ", .deepseek: "\t", .glm: "\n"]))
    }

    @Test("一家空白一家有值:仍需要确认")
    func mixed() {
        #expect(CredentialDraftEditing.hasUnsavedDraft([.kimi: "  ", .glm: "key"]))
    }
}
