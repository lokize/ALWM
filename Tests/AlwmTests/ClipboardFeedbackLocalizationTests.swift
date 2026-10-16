import Testing
import AlwmL10n

@Suite("Clipboard action feedback")
struct ClipboardFeedbackLocalizationTests {
    @Test("copy, pin, unpin, and delete confirmation text is available in Portuguese")
    func portugueseMessagesExist() {
        #expect(PluginL10n.t("plugin.clipboard.feedback.copied", locale: "pt-BR") == "Copiado para a área de transferência")
        #expect(PluginL10n.t("plugin.clipboard.feedback.pinned", locale: "pt-BR") == "Item fixado")
        #expect(PluginL10n.t("plugin.clipboard.feedback.unpinned", locale: "pt-BR") == "Item desafixado")
        #expect(PluginL10n.t("plugin.clipboard.feedback.deleted", locale: "pt-BR") == "Item excluído do histórico")
    }
}
