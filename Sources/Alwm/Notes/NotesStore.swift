import Foundation

@MainActor
public final class NotesStore: ObservableObject {
    public let undoManager = UndoManager()

    @Published private(set) var index = NotesIndexFile()
    @Published private(set) var loadedPages: [UUID: NotePage] = [:]
    @Published var openTabIDs: [UUID] = []
    @Published var activePageID: UUID?
    @Published var selectedCategoryID: UUID?
    @Published var searchQuery = ""
    @Published public private(set) var lastPersistenceError: String?
    @Published public private(set) var undoRevision = 0

    public var onIndexChanged: (() -> Void)?

    private var saveWorkItem: DispatchWorkItem?
    private var dirtyPageIDs: Set<UUID> = []
    private var saveGeneration: UInt64 = 0
    private let root: URL
    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var pagesDirectory: URL { root.appendingPathComponent("pages", isDirectory: true) }
    private func pageURL(_ id: UUID) -> URL {
        pagesDirectory.appendingPathComponent("\(id.uuidString).json")
    }
    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: pagesDirectory, withIntermediateDirectories: true)
    }
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

    public init(root: URL = NotesPaths.root) {
        self.root = root
        loadOrCreate()
    }

    public var defaultCategoryID: UUID {
        if let sel = selectedCategoryID { return sel }
        return index.categories.sorted(by: { $0.sortOrder < $1.sortOrder }).first?.id ?? bootstrapCategoryID()
    }

    public func loadOrCreate() {
        do {
            try ensureDirectories()
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let data = try Data(contentsOf: indexURL)
                do {
                    let decoded = try decoder.decode(NotesIndexFile.self, from: data)
                    index = decoded
                    openTabIDs = decoded.openTabIDs.filter { id in decoded.pages.contains { $0.id == id } }
                    selectedCategoryID = decoded.categories.sorted(by: { $0.sortOrder < $1.sortOrder }).first?.id
                    activePageID = openTabIDs.first
                    return
                } catch {
                    // Keep the damaged metadata for recovery; never replace it
                    // with an empty index and orphan all otherwise valid pages.
                    let backup = root.appendingPathComponent("index.corrupt-\(UUID().uuidString).json")
                    try FileManager.default.copyItem(at: indexURL, to: backup)
                    let urls = try FileManager.default.contentsOfDirectory(at: pagesDirectory, includingPropertiesForKeys: nil)
                    let pages = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url -> NotePage? in
                        guard url.pathExtension == "json", let bytes = try? Data(contentsOf: url) else { return nil }
                        return try? decoder.decode(NotePage.self, from: bytes)
                    }
                    let categoryIDs = Set(pages.map(\.categoryID))
                    index = NotesIndexFile(
                        categories: categoryIDs.sorted { $0.uuidString < $1.uuidString }.enumerated().map { offset, id in
                            NoteCategory(id: id, name: L10n.t("notepad.category.default"), sortOrder: offset)
                        },
                        pages: pages.map { NotePageSummary(id: $0.id, title: $0.title, categoryID: $0.categoryID, updatedAt: $0.updatedAt) },
                        recentPageIDs: pages.sorted { $0.updatedAt > $1.updatedAt }.map(\.id)
                    )
                    selectedCategoryID = index.categories.first?.id
                    recordPersistenceError(error)
                    persistIndex()
                    return
                }
            }
        } catch {
            recordPersistenceError(error)
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
        guard let data = try? Data(contentsOf: pageURL(id)),
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
        if !openTabIDs.contains(page.id) { openTabIDs.append(page.id) }
        activePageID = page.id
        if !persistPage(page) { dirtyPageIDs.insert(page.id) }
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

    public func updatePage(_ page: NotePage, registerUndo: Bool = false) {
        let previous = registerUndo ? self.page(page.id) : nil
        var p = page
        p.updatedAt = Date()
        if let previous, Self.hasContentChanges(from: previous, to: p) {
            undoManager.registerUndo(withTarget: self) { store in
                store.restorePage(previous)
            }
            undoManager.setActionName(L10n.t("notepad.undo.edit"))
        }
        commitPage(p)
    }

    private func restorePage(_ snapshot: NotePage) {
        guard let current = page(snapshot.id) else { return }
        undoManager.registerUndo(withTarget: self) { store in
            store.restorePage(current)
        }
        undoManager.setActionName(L10n.t("notepad.undo.edit"))

        var restored = snapshot
        restored.updatedAt = Date()
        commitPage(restored)
        undoRevision &+= 1
    }

    private func commitPage(_ p: NotePage) {
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

    private static func hasContentChanges(from old: NotePage, to new: NotePage) -> Bool {
        old.title != new.title || old.categoryID != new.categoryID || old.blocks != new.blocks
    }

    public func deletePage(_ id: UUID) {
        // Cancelled callbacks read the dirty set, never a captured stale page.
        dirtyPageIDs.remove(id)
        loadedPages.removeValue(forKey: id)
        index.pages.removeAll { $0.id == id }
        index.recentPageIDs.removeAll { $0 == id }
        openTabIDs.removeAll { $0 == id }
        if activePageID == id { activePageID = openTabIDs.last }
        try? FileManager.default.removeItem(at: pageURL(id))
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
        saveGeneration &+= 1
        saveWorkItem?.cancel()
        saveWorkItem = nil
        lastPersistenceError = nil
        for id in dirtyPageIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let page = loadedPages[id] else {
                dirtyPageIDs.remove(id)
                continue
            }
            if persistPage(page) { dirtyPageIDs.remove(id) }
        }
        if dirtyPageIDs.isEmpty { persistIndex() }
    }

    private func scheduleSave(_ page: NotePage) {
        loadedPages[page.id] = page
        dirtyPageIDs.insert(page.id)
        saveGeneration &+= 1
        let generation = saveGeneration
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.saveGeneration == generation else { return }
                self.flushPendingSaves()
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

    @discardableResult
    private func persistPage(_ page: NotePage) -> Bool {
        do {
            try ensureDirectories()
            let data = try encoder.encode(page)
            try data.write(to: pageURL(page.id), options: .atomic)
            return true
        } catch {
            recordPersistenceError(error)
            return false
        }
    }

    private func persistIndex() {
        var file = index
        file.openTabIDs = openTabIDs
        do {
            try ensureDirectories()
            let data = try encoder.encode(file)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            recordPersistenceError(error)
        }
    }

    private func recordPersistenceError(_ error: Error) {
        lastPersistenceError = error.localizedDescription
        NSLog("ALWM: notes persistence failed: %@", error.localizedDescription)
    }
}
