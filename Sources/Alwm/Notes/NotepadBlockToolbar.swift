import SwiftUI

/// Persistent block-type controls so users are not limited to typing `/`.
struct NotepadBlockToolbar: View {
    var activeKind: BlockKind?
    var onPick: (BlockKind) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                toolGroup(title: "notepad.toolbar.text", tools: [
                    (.paragraph, "text.alignleft"),
                    (.heading1, "textformat.size.larger"),
                    (.heading2, "textformat.size"),
                    (.heading3, "textformat")
                ])

                Divider().frame(height: 32)

                toolGroup(title: "notepad.toolbar.lists", tools: [
                    (.bulletList, "list.bullet"),
                    (.numberedList, "list.number"),
                    (.todo, "checkmark.square")
                ])

                Divider().frame(height: 32)

                toolGroup(title: "notepad.toolbar.blocks", tools: [
                    (.toggle, "chevron.right.square"),
                    (.code, "chevron.left.forwardslash.chevron.right"),
                    (.callout, "info.circle"),
                    (.divider, "minus")
                ])
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
        .background(shortcutButtons)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.55)
        }
    }

    private func toolGroup(title: String, tools: [(BlockKind, String)]) -> some View {
        VStack(spacing: 1) {
            Text(L10n.t(title))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            HStack(spacing: 3) {
                ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                    toolButton(kind: tool.0, icon: tool.1)
                }
            }
        }
    }

    private var shortcutButtons: some View {
        Group {
            Button("") { onPick(.heading1) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("") { onPick(.heading2) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("") { onPick(.heading3) }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("") { onPick(.bulletList) }
                .keyboardShortcut("8", modifiers: [.command, .option])
            Button("") { onPick(.numberedList) }
                .keyboardShortcut("9", modifiers: [.command, .option])
            Button("") { onPick(.todo) }
                .keyboardShortcut("t", modifiers: [.command, .option])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func toolButton(kind: BlockKind, icon: String) -> some View {
        let selected = activeKind == kind
        let shortcut = shortcutLabel(for: kind).map { " · \($0)" } ?? ""
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
        .help(title(for: kind) + shortcut)
    }

    private func shortcutLabel(for kind: BlockKind) -> String? {
        switch kind {
        case .heading1: return "⌘⌥1"
        case .heading2: return "⌘⌥2"
        case .heading3: return "⌘⌥3"
        case .bulletList: return "⌘⌥8"
        case .numberedList: return "⌘⌥9"
        case .todo: return "⌘⌥T"
        default: return nil
        }
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
