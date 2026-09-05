import SwiftUI

/// Persistent block-type controls so users are not limited to typing `/`.
struct NotepadBlockToolbar: View {
    var activeKind: BlockKind?
    var onPick: (BlockKind) -> Void

    private let tools: [(BlockKind, String)] = [
        (.paragraph, "text.alignleft"),
        (.heading1, "textformat.size.larger"),
        (.heading2, "textformat.size"),
        (.heading3, "textformat"),
        (.bulletList, "list.bullet"),
        (.numberedList, "list.number"),
        (.todo, "checkmark.square"),
        (.toggle, "chevron.right.square"),
        (.code, "chevron.left.forwardslash.chevron.right"),
        (.callout, "info.circle"),
        (.divider, "minus")
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(tools.enumerated()), id: \.offset) { index, tool in
                    if index == 1 || index == 4 || index == 8 {
                        Divider()
                            .frame(height: 18)
                            .padding(.horizontal, 2)
                    }
                    toolButton(kind: tool.0, icon: tool.1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.55)
        }
    }

    private func toolButton(kind: BlockKind, icon: String) -> some View {
        let selected = activeKind == kind
        return Button {
            onPick(kind)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 26)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.18) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title(for: kind))
    }

    private func title(for kind: BlockKind) -> String {
        switch kind {
        case .paragraph: return L10n.t("notepad.block.paragraph")
        case .heading1: return L10n.t("notepad.block.h1")
        case .heading2: return L10n.t("notepad.block.h2")
        case .heading3: return L10n.t("notepad.block.h3")
        case .bulletList: return L10n.t("notepad.block.bullet")
        case .numberedList: return L10n.t("notepad.block.numbered")
        case .todo: return L10n.t("notepad.block.todo")
        case .toggle: return L10n.t("notepad.block.toggle")
        case .code: return L10n.t("notepad.block.code")
        case .callout: return L10n.t("notepad.block.callout")
        case .divider: return L10n.t("notepad.block.divider")
        }
    }
}

struct NotepadInsertBlockMenu: View {
    var onPick: (BlockKind) -> Void

    var body: some View {
        Menu {
            ForEach(SlashCommands.all) { item in
                Button {
                    onPick(item.kind)
                } label: {
                    Label(item.title, systemImage: item.icon)
                }
            }
            Divider()
            Button {
                onPick(.paragraph)
            } label: {
                Label(L10n.t("notepad.block.paragraph"), systemImage: "text.alignleft")
            }
        } label: {
            Label(L10n.t("notepad.add_block"), systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        )
                )
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
