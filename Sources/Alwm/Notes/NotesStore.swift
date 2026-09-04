import Foundation

@MainActor
public final class NotesStore: ObservableObject {
    @Published private(set) var index = NotesIndexFile()
    @Published private(set) var loadedPages: [UUID: NotePage] = [:]
    @Published var openTabIDs: [UUID] = []
    @Published var activePageID: UUID?
    @Published var selectedCategoryID: UUID?
    @Published var searchQuery = ""

    public var onIndexChanged: (() -> Void)?

    private var saveWorkItem: DispatchWorkItem?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init() {
        loadOrCreate()
    }

    public var defaultCategoryID: UUID {
        if let sel = selectedCategoryID { return sel }
        return index.categories.sorted(by: { $0.sortOrder < $1.sortOrder }).first?.id ?? bootstrapCategoryID()
    }

    public func loadOrCreate() {
        try? NotesPaths.ensureDirectories()
        if let data = try? Data(contentsOf: NotesPaths.index),
           let decoded = try? decoder.decode(NotesIndexFile.self, from: data) {
            index = decoded
            openTabIDs = decoded.openTabIDs
            selectedCategoryID = decoded.categories.sorted(by: { $0.sortOrder < $1.sortOrder }).first?.id
            activePageID = openTabIDs.first
            return
        }
        let cat = NoteCategory(name: L10n.t("notepad.category.default"))
        index = NotesIndexFile(categories: [cat])
        selectedCategoryID = cat.id
        persistIndex()
    }

    private func bootstrapCategoryID() -> UUID {
        if let first = index.categories.first?.id { return first }
        let cat = NoteCategory(name: L10n.t("notepad.category.default"))
        index.categories.append(cat)
        persistIndex()
        return cat.id
    }

    public func page(_ id: UUID) -> NotePage? {
        if let cached = loadedPages[id] { return cached }
        guard let data = try? Data(contentsOf: NotesPaths.pageURL(id)),
              let page = try? decoder.decode(NotePage.self, from: data) else { return nil }
        loadedPages[id] = page
        return page
    }

    @discardableResult
    public func createPage(title: String? = nil, categoryID: UUID? = nil) -> NotePage {
        let cat = categoryID ?? defaultCategoryID
        let page = NotePage(
            title: title ?? L10n.t("notepad.untitled"),
            categoryID: cat,
            blocks: [NoteBlock.empty()]
        )
        loadedPages[page.id] = page
        index.pages.append(NotePageSummary(
            id: page.id,
            title: page.title,
            categoryID: page.categoryID,
            updatedAt: page.updatedAt
        ))
        touchRecent(page.id)
        openTab(page.id)
        persistPage(page)
        persistIndex()
        onIndexChanged?()
        return page
    }

    public func openTab(_ id: UUID) {
        if !openTabIDs.contains(id) {
            openTabIDs.append(id)
        }
        activePageID = id
        _ = page(id)
        persistIndex()
    }

    public func closeTab(_ id: UUID) {
        openTabIDs.removeAll { $0 == id }
        if activePageID == id {
            activePageID = openTabIDs.last
        }
        persistIndex()
    }

    public func updatePage(_ page: NotePage) {
        var p = page
        p.updatedAt = Date()
        loadedPages[p.id] = p
        if let idx = index.pages.firstIndex(where: { $0.id == p.id }) {
            index.pages[idx] = NotePageSummary(
                id: p.id,
                title: p.title.isEmpty ? L10n.t("notepad.untitled") : p.title,
                categoryID: p.categoryID,
                updatedAt: p.updatedAt
            )
        }
        touchRecent(p.id)
        scheduleSave(p)
    }

    public func deletePage(_ id: UUID) {
        loadedPages.removeValue(forKey: id)
        index.pages.removeAll { $0.id == id }
        index.recentPageIDs.removeAll { $0 == id }
        openTabIDs.removeAll { $0 == id }
        if activePageID == id { activePageID = openTabIDs.last }
        try? FileManager.default.removeItem(at: NotesPaths.pageURL(id))
        persistIndex()
        onIndexChanged?()
    }

    public func addCategory(name: String) {
        let order = (index.categories.map(\.sortOrder).max() ?? -1) + 1
        let cat = NoteCategory(name: name, sortOrder: order)
        index.categories.append(cat)
        selectedCategoryID = cat.id
        persistIndex()
        onIndexChanged?()
    }

    public func renameCategory(_ id: UUID, name: String) {
        guard let idx = index.categories.firstIndex(where: { $0.id == id }) else { return }
        index.categories[idx].name = name
        persistIndex()
        onIndexChanged?()
    }

    public func filteredSummaries() -> [NotePageSummary] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var list = index.pages
        if let cat = selectedCategoryID {
            list = list.filter { $0.categoryID == cat }
        }
        list.sort { $0.updatedAt > $1.updatedAt }
        guard !q.isEmpty else { return list }
        return list.filter { summary in
            if summary.title.lowercased().contains(q) { return true }
            guard let page = page(summary.id) else { return false }
            return page.blocks.contains { Self.blockText($0).lowercased().contains(q) }
        }
    }

    public func recentPreviews(limit: Int = 4) -> [NotePreview] {
        let ordered = index.recentPageIDs.prefix(limit)
        return ordered.compactMap { id in
            guard let summary = index.pages.first(where: { $0.id == id }) else { return nil }
            let excerpt = page(id).map { Self.excerpt(for: $0) } ?? ""
            return NotePreview(
                id: id,
                title: summary.title,
                excerpt: excerpt,
                updatedAt: summary.updatedAt
            )
        }
    }

    public static func excerpt(for page: NotePage, maxLen: Int = 80) -> String {
        for block in page.blocks {
            let t = blockText(block).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                if t.count <= maxLen { return t }
                return String(t.prefix(maxLen - 1)) + "…"
            }
            for child in block.children {
                let ct = blockText(child).trimmingCharacters(in: .whitespacesAndNewlines)
                if !ct.isEmpty {
                    if ct.count <= maxLen { return ct }
                    return String(ct.prefix(maxLen - 1)) + "…"
                }
            }
        }
        return L10n.t("notepad.empty_excerpt")
    }

    public static func blockText(_ block: NoteBlock) -> String {
        switch block.kind {
        case .divider: return ""
        default: return block.text
        }
    }

    public func flushPendingSaves() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
        for (_, page) in loadedPages {
            persistPage(page)
        }
        persistIndex()
    }

    private func scheduleSave(_ page: NotePage) {
        loadedPages[page.id] = page
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.persistPage(page)
                self.persistIndex()
                self.onIndexChanged?()
            }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func touchRecent(_ id: UUID) {
        index.recentPageIDs.removeAll { $0 == id }
        index.recentPageIDs.insert(id, at: 0)
        if index.recentPageIDs.count > 32 {
            index.recentPageIDs = Array(index.recentPageIDs.prefix(32))
        }
    }

    private func persistPage(_ page: NotePage) {
        try? NotesPaths.ensureDirectories()
        if let data = try? encoder.encode(page) {
            try? data.write(to: NotesPaths.pageURL(page.id), options: .atomic)
        }
    }

    private func persistIndex() {
        var file = index
        file.openTabIDs = openTabIDs
        if let data = try? encoder.encode(file) {
            try? data.write(to: NotesPaths.index, options: .atomic)
        }
    }
}
