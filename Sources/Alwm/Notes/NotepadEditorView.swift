import SwiftUI

struct NotepadEditorView: View {
    @ObservedObject var store: NotesStore
    @State private var focusedBlockID: UUID?
    @State private var draftPage: NotePage?
    @State private var isCompletedTasksExpanded = false

    private var currentPage: NotePage? {
        guard let activeID = store.activePageID, let base = store.page(activeID) else { return nil }
        return draftPage ?? base
    }

    private var activeBlockKind: BlockKind? {
        guard let page = currentPage, let id = focusedBlockID,
              let block = page.blocks.first(where: { $0.id == id }) else { return nil }
        return block.kind
    }

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
        .onChange(of: store.activePageID) { _, _ in
            isCompletedTasksExpanded = false
            store.undoManager.removeAllActions()
            reloadDraft()
        }
        .onChange(of: store.undoRevision) { _, _ in syncDraftAfterUndo() }
        .onAppear { reloadDraft() }
    }

    @ViewBuilder
    private func editorContent(page: NotePage) -> some View {
        VStack(spacing: 0) {
            NotepadBlockToolbar(activeKind: activeBlockKind) { kind in
                applyTool(kind, page: page)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    TextField(L10n.t("notepad.title_placeholder"), text: titleBinding(page: page))
                        .font(.system(size: 28, weight: .bold))
                        .textFieldStyle(.plain)
                        .padding(.top, 4)
                        .padding(.bottom, 4)

                    Text(L10n.t("notepad.toolbar.hint"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 8)

                    blockList(page: page)

                    NotepadInsertBlockMenu { kind in
                        insertBlock(after: (draftPage ?? page).blocks.last?.id, kind: kind, page: page)
                    }
                    .padding(.top, 10)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func blockList(page: NotePage) -> some View {
        let blocks = (draftPage ?? page).blocks
        let indexed = blocks.enumerated().map {
            IndexedNoteBlock(sourceIndex: $0.offset, block: $0.element)
        }
        let pendingTasks = indexed.filter { $0.block.kind == .todo && !$0.block.checked }
        let completedTasks = indexed.filter { $0.block.kind == .todo && $0.block.checked }
        let noteBlocks = indexed.filter { $0.block.kind != .todo }

        VStack(alignment: .leading, spacing: 6) {
            if !pendingTasks.isEmpty {
                Text("\(L10n.t("notepad.tasks.pending")) (\(pendingTasks.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                blockRows(pendingTasks, page: page, allBlocks: blocks)
            }

            if !completedTasks.isEmpty {
                DisclosureGroup(isExpanded: $isCompletedTasksExpanded) {
                    blockRows(completedTasks, page: page, allBlocks: blocks)
                        .padding(.top, 4)
                } label: {
                    Text("\(L10n.t("notepad.tasks.completed")) (\(completedTasks.count))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            if (!pendingTasks.isEmpty || !completedTasks.isEmpty) && !noteBlocks.isEmpty {
                Divider().padding(.vertical, 3)
            }

            blockRows(noteBlocks, page: page, allBlocks: blocks)
        }
    }

    @ViewBuilder
    private func blockRows(
        _ entries: [IndexedNoteBlock],
        page: NotePage,
        allBlocks: [NoteBlock]
    ) -> some View {
        ForEach(Array(entries.enumerated()), id: \.element.id) { visibleIndex, entry in
            let idx = entry.sourceIndex
            BlockRowView(
                block: blockBinding(at: idx, page: page),
                canMoveUp: visibleIndex > 0,
                canMoveDown: visibleIndex + 1 < entries.count,
                numberedIndex: numberedIndex(for: idx, in: allBlocks),
                focusedBlockID: focusedBlockID,
                onFocus: { focusedBlockID = $0 },
                onEnter: { id in insertBlock(after: id, kind: .paragraph, page: page) },
                onBackspaceEmpty: { id in deleteBlock(id, page: page) },
                onDuplicateBlock: { id in duplicateBlock(id, page: page) },
                onSlashCommand: { id, kind in applySlash(id, kind: kind, page: page) },
                onChangeKind: { id, kind in applySlash(id, kind: kind, page: page) },
                onMoveBlock: { id, direction in moveBlock(id, direction: direction, page: page) }
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
                let oldBlock = p.blocks[index]
                p.blocks[index] = new
                draftPage = p
                store.updatePage(p, registerUndo: blockChangeNeedsUndo(from: oldBlock, to: new))
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
            focusedBlockID = nil
            return
        }
        draftPage = p
        focusedBlockID = p.blocks.first?.id
    }

    private func syncDraftAfterUndo() {
        guard let id = store.activePageID, let restored = store.page(id) else { return }
        draftPage = restored
        if let focusedBlockID, !containsBlock(focusedBlockID, in: restored.blocks) {
            self.focusedBlockID = restored.blocks.first?.id
        }
    }

    private func containsBlock(_ id: UUID, in blocks: [NoteBlock]) -> Bool {
        blocks.contains { block in
            block.id == id || containsBlock(id, in: block.children)
        }
    }

    private func numberedIndex(for index: Int, in blocks: [NoteBlock]) -> Int {
        var n = 0
        for i in 0...index where i < blocks.count {
            if blocks[i].kind == .numberedList { n += 1 }
        }
        return max(1, n)
    }

    /// Toolbar: convert empty focused block, otherwise insert after focus.
    private func applyTool(_ kind: BlockKind, page: NotePage) {
        let p = draftPage ?? page
        if let id = focusedBlockID,
           let block = p.blocks.first(where: { $0.id == id }),
           block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applySlash(id, kind: kind, page: page)
            return
        }
        insertBlock(after: focusedBlockID ?? p.blocks.last?.id, kind: kind, page: page)
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
        store.updatePage(p, registerUndo: true)
    }

    private func deleteBlock(_ id: UUID, page: NotePage) {
        var p = draftPage ?? page
        guard p.blocks.count > 1, let idx = p.blocks.firstIndex(where: { $0.id == id }) else { return }
        p.blocks.remove(at: idx)
        draftPage = p
        focusedBlockID = p.blocks[max(0, idx - 1)].id
        store.updatePage(p, registerUndo: true)
    }

    private func duplicateBlock(_ id: UUID, page: NotePage) {
        var p = draftPage ?? page
        guard let idx = p.blocks.firstIndex(where: { $0.id == id }) else { return }
        let duplicate = p.blocks[idx].copyWithNewIDs()
        p.blocks.insert(duplicate, at: idx + 1)
        draftPage = p
        focusedBlockID = duplicate.id
        store.updatePage(p, registerUndo: true)
    }

    private func blockChangeNeedsUndo(from old: NoteBlock, to new: NoteBlock) -> Bool {
        var oldWithoutText = old
        var newWithoutText = new
        clearText(in: &oldWithoutText)
        clearText(in: &newWithoutText)
        return oldWithoutText != newWithoutText
    }

    private func clearText(in block: inout NoteBlock) {
        block.text = ""
        for index in block.children.indices {
            clearText(in: &block.children[index])
        }
    }

    private func applySlash(_ id: UUID, kind: BlockKind, page: NotePage) {
        var p = draftPage ?? page
        guard let idx = p.blocks.firstIndex(where: { $0.id == id }) else { return }
        p.blocks[idx].kind = kind
        if let range = p.blocks[idx].text.range(of: "/", options: .backwards) {
            let prefix = p.blocks[idx].text[..<range.lowerBound]
            p.blocks[idx].text = String(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if kind == .toggle, p.blocks[idx].children.isEmpty {
            p.blocks[idx].children = [NoteBlock.empty()]
        }
        if kind == .divider {
            p.blocks[idx].text = ""
        }
        draftPage = p
        focusedBlockID = id
        store.updatePage(p, registerUndo: true)
    }

    private func moveBlock(_ id: UUID, direction: Int, page: NotePage) {
        var p = draftPage ?? page
        guard direction == -1 || direction == 1,
              let sourceIndex = p.blocks.firstIndex(where: { $0.id == id }) else { return }
        let source = p.blocks[sourceIndex]
        let siblingIndices = p.blocks.indices.filter { index in
            let candidate = p.blocks[index]
            if source.kind == .todo {
                return candidate.kind == .todo && candidate.checked == source.checked
            }
            return candidate.kind != .todo
        }
        guard let siblingPosition = siblingIndices.firstIndex(of: sourceIndex) else { return }
        let targetPosition = siblingPosition + direction
        guard targetPosition >= 0, targetPosition < siblingIndices.count else { return }
        let targetIndex = siblingIndices[targetPosition]
        let destination = direction < 0 ? targetIndex : targetIndex + 1
        p.blocks.move(fromOffsets: IndexSet(integer: sourceIndex), toOffset: destination)
        draftPage = p
        store.updatePage(p, registerUndo: true)
    }
}

private struct IndexedNoteBlock: Identifiable {
    var sourceIndex: Int
    var block: NoteBlock
    var id: UUID { block.id }
}
