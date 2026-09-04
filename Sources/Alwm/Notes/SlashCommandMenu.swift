import SwiftUI

struct SlashCommand: Identifiable, Hashable {
    let id: BlockKind
    let title: String
    let icon: String
    let kind: BlockKind
}

enum SlashCommands {
    static var all: [SlashCommand] {
        [
            SlashCommand(id: .heading1, title: L10n.t("notepad.block.h1"), icon: "textformat.size.larger", kind: .heading1),
            SlashCommand(id: .heading2, title: L10n.t("notepad.block.h2"), icon: "textformat.size", kind: .heading2),
            SlashCommand(id: .heading3, title: L10n.t("notepad.block.h3"), icon: "textformat", kind: .heading3),
            SlashCommand(id: .bulletList, title: L10n.t("notepad.block.bullet"), icon: "list.bullet", kind: .bulletList),
            SlashCommand(id: .numberedList, title: L10n.t("notepad.block.numbered"), icon: "list.number", kind: .numberedList),
            SlashCommand(id: .todo, title: L10n.t("notepad.block.todo"), icon: "checkmark.square", kind: .todo),
            SlashCommand(id: .toggle, title: L10n.t("notepad.block.toggle"), icon: "chevron.right.square", kind: .toggle),
            SlashCommand(id: .code, title: L10n.t("notepad.block.code"), icon: "chevron.left.forwardslash.chevron.right", kind: .code),
            SlashCommand(id: .callout, title: L10n.t("notepad.block.callout"), icon: "info.circle", kind: .callout),
            SlashCommand(id: .divider, title: L10n.t("notepad.block.divider"), icon: "minus", kind: .divider)
        ]
    }
}

struct SlashCommandMenu: View {
    let filter: String
    let onPick: (BlockKind) -> Void

    private var items: [SlashCommand] {
        let q = filter.lowercased()
        let base = SlashCommands.all
        guard !q.isEmpty else { return base }
        return base.filter { $0.title.lowercased().contains(q) || $0.kind.rawValue.contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { item in
                Button {
                    onPick(item.kind)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon)
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text(item.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 220)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}
