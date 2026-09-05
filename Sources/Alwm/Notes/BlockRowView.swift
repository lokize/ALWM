import SwiftUI

struct BlockRowView: View {
    @Binding var block: NoteBlock
    var index: Int
    var numberedIndex: Int
    var focusedBlockID: UUID?
    var onFocus: (UUID) -> Void
    var onEnter: (UUID) -> Void
    var onBackspaceEmpty: (UUID) -> Void
    var onSlashCommand: (UUID, BlockKind) -> Void
    var onChangeKind: (UUID, BlockKind) -> Void
    var onMoveBlock: (IndexSet, Int) -> Void

    @State private var slashFilter = ""
    @State private var showSlash = false
    @State private var hovered = false
    @FocusState private var isFocused: Bool

    private var isActive: Bool { focusedBlockID == block.id || isFocused || hovered }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            blockChrome

            VStack(alignment: .leading, spacing: 6) {
                blockContent
                if showSlash {
                    SlashCommandMenu(filter: slashFilter) { kind in
                        showSlash = false
                        slashFilter = ""
                        onSlashCommand(block.id, kind)
                    }
                }
                if block.kind == .toggle, !block.collapsed {
                    ForEach(Array(block.children.enumerated()), id: \.element.id) { childIdx, child in
                        HStack(alignment: .top, spacing: 6) {
                            Color.clear.frame(width: 8)
                            childRow(child, childIdx: childIdx)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Color.primary.opacity(0.045) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .padding(.vertical, 1)
        .onHover { hovered = $0 }
        .onAppear {
            if focusedBlockID == block.id {
                isFocused = true
            }
        }
        .onChange(of: focusedBlockID) { _, new in
            isFocused = new == block.id
        }
    }

    private var blockChrome: some View {
        VStack(spacing: 2) {
            if block.kind != .divider {
                Image(systemName: "line.3.horizontal")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isActive ? .secondary : .tertiary)
                    .frame(width: 16, height: 16)
                    .opacity(isActive ? 1 : 0.35)
            } else {
                Color.clear.frame(width: 16, height: 16)
            }

            Menu {
                ForEach(SlashCommands.all) { item in
                    Button {
                        onChangeKind(block.id, item.kind)
                    } label: {
                        Label(item.title, systemImage: item.icon)
                    }
                }
                Divider()
                Button {
                    onChangeKind(block.id, .paragraph)
                } label: {
                    Label(L10n.t("notepad.block.paragraph"), systemImage: "text.alignleft")
                }
            } label: {
                Image(systemName: kindIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(isActive ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 4))
            }
            .menuStyle(.borderlessButton)
            .opacity(isActive ? 1 : 0.4)
            .help(L10n.t("notepad.change_block"))
        }
        .padding(.top, 4)
        .frame(width: 22)
    }

    private var kindIcon: String {
        switch block.kind {
        case .paragraph: return "text.alignleft"
        case .heading1: return "textformat.size.larger"
        case .heading2: return "textformat.size"
        case .heading3: return "textformat"
        case .bulletList: return "list.bullet"
        case .numberedList: return "list.number"
        case .todo: return "checkmark.square"
        case .toggle: return "chevron.right.square"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .callout: return "info.circle"
        case .divider: return "minus"
        }
    }

    @ViewBuilder
    private var blockContent: some View {
        switch block.kind {
        case .divider:
            Divider().padding(.vertical, 10)
        case .code:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(L10n.t("notepad.block.code"), systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $block.language) {
                        Text("Swift").tag("swift")
                        Text("JSON").tag("json")
                        Text("Shell").tag("shell")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                TextEditor(text: $block.text)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 88)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                    .focused($isFocused)
            }
        case .callout:
            HStack(alignment: .top, spacing: 10) {
                calloutIcon
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $block.calloutStyle) {
                        ForEach(CalloutStyle.allCases) { s in
                            Text(s.rawValue.capitalized).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 240)
                    editableField(font: .body)
                }
            }
            .padding(12)
            .background(calloutColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(calloutColor.opacity(0.4)))
        case .todo:
            HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: $block.checked)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .padding(.top, 2)
                editableField(font: .body)
                    .strikethrough(block.checked)
                    .foregroundStyle(block.checked ? .secondary : .primary)
            }
        case .toggle:
            HStack(alignment: .top, spacing: 8) {
                Button {
                    block.collapsed.toggle()
                } label: {
                    Image(systemName: block.collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                editableField(font: .body.weight(.medium))
            }
        case .bulletList:
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                editableField(font: .body)
            }
        case .numberedList:
            HStack(alignment: .top, spacing: 8) {
                Text("\(numberedIndex).")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
                editableField(font: .body)
            }
        case .heading1:
            editableField(font: .system(size: 28, weight: .bold))
        case .heading2:
            editableField(font: .system(size: 22, weight: .semibold))
        case .heading3:
            editableField(font: .system(size: 17, weight: .semibold))
        case .paragraph:
            editableField(font: .body)
        }
    }

    private func childRow(_ child: NoteBlock, childIdx: Int) -> some View {
        BlockRowView(
            block: bindingForChild(at: childIdx),
            index: childIdx,
            numberedIndex: childIdx + 1,
            focusedBlockID: focusedBlockID,
            onFocus: onFocus,
            onEnter: { _ in },
            onBackspaceEmpty: { _ in },
            onSlashCommand: { _, _ in },
            onChangeKind: { _, _ in },
            onMoveBlock: { _, _ in }
        )
    }

    private func bindingForChild(at idx: Int) -> Binding<NoteBlock> {
        Binding(
            get: { block.children[idx] },
            set: { block.children[idx] = $0 }
        )
    }

    private func editableField(font: Font) -> some View {
        TextField(L10n.t("notepad.placeholder"), text: $block.text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(font)
            .focused($isFocused)
            .onChange(of: isFocused) { _, focused in
                if focused { onFocus(block.id) }
            }
            .onSubmit { onEnter(block.id) }
            .onChange(of: block.text) { _, new in
                if new == "/" || new.hasSuffix("\n/") {
                    showSlash = true
                    slashFilter = ""
                } else if new.contains("/") && showSlash {
                    if let range = new.range(of: "/", options: .backwards) {
                        slashFilter = String(new[range.upperBound...])
                    }
                } else if !new.contains("/") {
                    showSlash = false
                    slashFilter = ""
                }
                if new.isEmpty && isFocused {
                    onBackspaceEmpty(block.id)
                }
            }
    }

    private var calloutColor: Color {
        switch block.calloutStyle {
        case .info: return .blue
        case .warn: return .orange
        case .tip: return .green
        }
    }

    private var calloutIcon: some View {
        let name: String = switch block.calloutStyle {
        case .info: "info.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .tip: "lightbulb.fill"
        }
        return Image(systemName: name)
            .foregroundStyle(calloutColor)
            .padding(.top, 4)
    }
}
