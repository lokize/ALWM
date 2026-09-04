import SwiftUI

struct NotepadEditorView: View {
    @ObservedObject var store: NotesStore
    @State private var focusedBlockID: UUID?
    @State private var draftPage: NotePage?

    var body: some View {
        Group {
            if let activeID = store.activePageID, let base = store.page(activeID) {
                editorContent(page: draftPage ?? base)
            } else {
                ContentUnavailableView(
                    L10n.t("notepad.no_page"),
                    systemImage: "note.text",
                    description: Text(L10n.t("notepad.no_page.help"))
                )
            }
        }
        .onChange(of: store.activePageID) { _, _ in reloadDraft() }
        .onAppear { reloadDraft() }
    }

    @ViewBuilder
    private func editorContent(page: NotePage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                TextField(L10n.t("notepad.title_placeholder"), text: titleBinding(page: page))
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .padding(.bottom, 8)

                blockList(page: page)

                Button {
                    insertBlock(after: (draftPage ?? page).blocks.last?.id, kind: .paragraph, page: page)
                } label: {
                    Label(L10n.t("notepad.add_block"), systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func blockList(page: NotePage) -> some View {
        let blocks = (draftPage ?? page).blocks
        ForEach(Array(blocks.enumerated()), id: \.element.id) { idx, block in
            BlockRowView(
                block: blockBinding(at: idx, page: page),
                index: idx,
                numberedIndex: numberedIndex(for: idx, in: blocks),
                focusedBlockID: focusedBlockID,
                onFocus: { focusedBlockID = $0 },
                onEnter: { id in insertBlock(after: id, kind: .paragraph, page: page) },
                onBackspaceEmpty: { id in deleteBlock(id, page: page) },
                onSlashCommand: { id, kind in applySlash(id, kind: kind, page: page) },
                onMoveBlock: { from, to in moveBlocks(from: from, to: to, page: page) }
            )
        }
    }

    private func blockBinding(at index: Int, page: NotePage) -> Binding<NoteBlock> {
        Binding(
            get: {
                let p = draftPage ?? page
                guard index < p.blocks.count else { return NoteBlock.empty() }
                return p.blocks[index]
            },
            set: { new in
                var p = draftPage ?? page
                guard index < p.blocks.count else { return }
                p.blocks[index] = new
                draftPage = p
                store.updatePage(p)
            }
        )
    }

    private func titleBinding(page: NotePage) -> Binding<String> {
        Binding(
            get: { draftPage?.title ?? page.title },
            set: { new in
                var p = draftPage ?? page
                p.title = new
                draftPage = p
                store.updatePage(p)
            }
        )
    }

    private func reloadDraft() {
        guard let id = store.activePageID, let p = store.page(id) else {
            draftPage = nil
            return
        }
        draftPage = p
    }

    private func numberedIndex(for index: Int, in blocks: [NoteBlock]) -> Int {
        var n = 0
        for i in 0...index where i < blocks.count {
            if blocks[i].kind == .numberedList { n += 1 }
        }
        return max(1, n)
    }

    private func insertBlock(after id: UUID?, kind: BlockKind, page: NotePage) {
        var p = draftPage ?? page
        var block = NoteBlock.empty(kind)
        if kind == .toggle {
            block.children = [NoteBlock.empty()]
        }
        if let id, let idx = p.blocks.firstIndex(where: { $0.id == id }) {
            p.blocks.insert(block, at: idx + 1)
        } else {
            p.blocks.append(block)
        }
        draftPage = p
        focusedBlockID = block.id
        store.updatePage(p)
    }

    private func deleteBlock(_ id: UUID, page: NotePage) {
        var p = draftPage ?? page
        guard p.blocks.count > 1, let idx = p.blocks.firstIndex(where: { $0.id == id }) else { return }
        p.blocks.remove(at: idx)
        draftPage = p
        focusedBlockID = p.blocks[max(0, idx - 1)].id
        store.updatePage(p)
    }

    private func applySlash(_ id: UUID, kind: BlockKind, page: NotePage) {
        var p = draftPage ?? page
        guard let idx = p.blocks.firstIndex(where: { $0.id == id }) else { return }
        p.blocks[idx].kind = kind
        p.blocks[idx].text = p.blocks[idx].text
            .replacingOccurrences(of: "/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .toggle, p.blocks[idx].children.isEmpty {
            p.blocks[idx].children = [NoteBlock.empty()]
        }
        if kind == .divider {
            p.blocks[idx].text = ""
        }
        draftPage = p
        store.updatePage(p)
    }

    private func moveBlocks(from: IndexSet, to: Int, page: NotePage) {
        var p = draftPage ?? page
        p.blocks.move(fromOffsets: from, toOffset: to)
        draftPage = p
        store.updatePage(p)
    }
}
