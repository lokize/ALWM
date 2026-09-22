import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import AlwmL10n

enum ClipboardKind: String, Codable, CaseIterable, Sendable {
    case text
    case link
    case image
    case video
    case file

    var symbolName: String {
        switch self {
        case .text: return "doc.text"
        case .link: return "link"
        case .image: return "photo"
        case .video: return "film"
        case .file: return "doc"
        }
    }
}

enum ClipboardFilter: String, CaseIterable, Sendable {
    case all
    case text
    case link
    case image
    case video
    case file
}

struct ClipboardItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: ClipboardKind
    let createdAt: Date
    let preview: String
    let detail: String?
    let text: String?
    let imagePath: String?
    let fileURL: URL?
    let sourceApp: String?
    let byteSize: Int?
    let contentKey: String
    var pinned: Bool

    var searchBlob: String {
        [preview, detail, text, fileURL?.lastPathComponent, sourceApp]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }
}

struct ClipboardSettings: Codable, Equatable, Sendable {
    var maxItems: Int = 100
    /// Skip items larger than this many bytes (images / files metadata).
    var maxMediaBytes: Int = 8 * 1024 * 1024
}

final class ClipboardStore: ObservableObject, @unchecked Sendable {
    static let shared = ClipboardStore()

    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var settings = ClipboardSettings()
    @Published var searchQuery: String = ""
    @Published var filter: ClipboardFilter = .all
    @Published var selectedID: UUID?

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private var pollTimer: Timer?
    private var lastChangeCount: Int = -1
    private let lock = NSLock()
    private let pasteboard = NSPasteboard.general
    private var ignoringNextCapture = false

    private static let maxTextChars = 200_000

    private init() {
        loadSettings()
        loadHistory()
    }

    var itemCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    var barLabel: String {
        "\(itemCount)"
    }

    var barTint: NSColor {
        itemCount > 0 ? .systemTeal : .labelColor
    }

    var tooltip: String {
        let loc = localeCode()
        let n = itemCount
        if n == 0 {
            return PluginL10n.t("plugin.clipboard.tooltip.empty", locale: loc)
        }
        if n == 1 {
            return PluginL10n.t("plugin.clipboard.tooltip.count_one", locale: loc)
        }
        return PluginL10n.tf("plugin.clipboard.tooltip.count", locale: loc, n)
    }

    func countLabel() -> String {
        let loc = localeCode()
        let n = itemCount
        if n == 1 {
            return PluginL10n.t("plugin.clipboard.count_one", locale: loc)
        }
        return PluginL10n.tf("plugin.clipboard.count", locale: loc, n)
    }

    var filteredItems: [ClipboardItem] {
        lock.lock()
        let all = items
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let f = filter
        lock.unlock()

        return all.filter { item in
            switch f {
            case .all: break
            case .text: if item.kind != .text { return false }
            case .link: if item.kind != .link { return false }
            case .image: if item.kind != .image { return false }
            case .video: if item.kind != .video { return false }
            case .file: if item.kind != .file { return false }
            }
            if q.isEmpty { return true }
            return item.searchBlob.contains(q)
        }
    }

    var selectedItem: ClipboardItem? {
        let rows = filteredItems
        if let id = selectedID, let hit = rows.first(where: { $0.id == id }) {
            return hit
        }
        return rows.first
    }

    func start() {
        loadHistory()
        if pollTimer == nil {
            lastChangeCount = pasteboard.changeCount
            let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
                self?.pollPasteboard()
            }
            RunLoop.main.add(t, forMode: .common)
            pollTimer = t
        }
        pollPasteboard(force: true)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        persistHistory()
        saveSettings()
    }

    func copyItem(_ item: ClipboardItem) {
        writeToPasteboard(item)
    }

    /// Copy into pasteboard, close UI, then ⌘V into the frontmost app.
    func pasteItem(_ item: ClipboardItem) {
        writeToPasteboard(item)
        Task { @MainActor in
            ClipboardPanelController.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                ClipboardPaster.pasteCommandV()
            }
        }
    }

    func pasteSelected() {
        guard let item = selectedItem else { return }
        pasteItem(item)
    }

    func selectNext() {
        let rows = filteredItems
        guard !rows.isEmpty else { return }
        if let id = selectedID, let idx = rows.firstIndex(where: { $0.id == id }) {
            selectedID = rows[min(idx + 1, rows.count - 1)].id
        } else {
            selectedID = rows.first?.id
        }
        objectWillChange.send()
    }

    func selectPrevious() {
        let rows = filteredItems
        guard !rows.isEmpty else { return }
        if let id = selectedID, let idx = rows.firstIndex(where: { $0.id == id }) {
            selectedID = rows[max(idx - 1, 0)].id
        } else {
            selectedID = rows.first?.id
        }
        objectWillChange.send()
    }

    func ensureSelection() {
        let rows = filteredItems
        if let id = selectedID, rows.contains(where: { $0.id == id }) { return }
        selectedID = rows.first?.id
        objectWillChange.send()
    }

    func pasteMostRecent() {
        lock.lock()
        let item = items.first
        lock.unlock()
        guard let item else { return }
        pasteItem(item)
    }

    func togglePin(_ item: ClipboardItem) {
        lock.lock()
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else {
            lock.unlock()
            return
        }
        items[idx].pinned.toggle()
        sortItemsLocked()
        lock.unlock()
        persistHistory()
        objectWillChange.send()
        onChange?()
    }

    func deleteItem(_ item: ClipboardItem) {
        lock.lock()
        items.removeAll { $0.id == item.id }
        if selectedID == item.id { selectedID = items.first?.id }
        lock.unlock()
        removeMedia(for: item)
        persistHistory()
        objectWillChange.send()
        onChange?()
    }

    func clearUnpinned() {
        lock.lock()
        let removed = items.filter { !$0.pinned }
        items.removeAll { !$0.pinned }
        lock.unlock()
        for item in removed { removeMedia(for: item) }
        persistHistory()
        ensureSelection()
        objectWillChange.send()
        onChange?()
    }

    func clearAll() {
        lock.lock()
        let removed = items
        items = []
        selectedID = nil
        lock.unlock()
        for item in removed { removeMedia(for: item) }
        persistHistory()
        objectWillChange.send()
        onChange?()
    }

    func updateSettings(_ mutate: (inout ClipboardSettings) -> Void) {
        mutate(&settings)
        // 0 = keep everything; otherwise clamp to 10…200 in steps of 10.
        if settings.maxItems <= 0 {
            settings.maxItems = 0
        } else {
            let snapped = Int((Double(settings.maxItems) / 10.0).rounded()) * 10
            settings.maxItems = min(200, max(10, snapped))
        }
        settings.maxMediaBytes = min(50 * 1024 * 1024, max(512 * 1024, settings.maxMediaBytes))
        saveSettings()
        trimToMax()
        objectWillChange.send()
        onChange?()
    }

    /// Cycle: … → 10 → 0 (all) → 200 → 190 → … when stepping past the ends.
    func stepMaxItems(_ direction: Int) {
        updateSettings { s in
            if s.maxItems <= 0 {
                s.maxItems = direction > 0 ? 10 : 200
            } else if direction > 0 {
                s.maxItems = s.maxItems >= 200 ? 0 : s.maxItems + 10
            } else {
                s.maxItems = s.maxItems <= 10 ? 0 : s.maxItems - 10
            }
        }
    }

    var keepsAllItems: Bool { settings.maxItems <= 0 }

    func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard item.kind == .image, let path = item.imagePath else { return nil }
        return NSImage(contentsOfFile: path)
    }

    func openOriginal(_ item: ClipboardItem) {
        if let url = item.fileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        if let path = item.imagePath {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    // MARK: - Capture

    private func pollPasteboard(force: Bool = false) {
        let count = pasteboard.changeCount
        guard force || count != lastChangeCount else { return }
        lastChangeCount = count
        if ignoringNextCapture {
            ignoringNextCapture = false
            return
        }
        guard let captured = captureCurrent() else { return }
        insert(captured)
    }

    private func writeToPasteboard(_ item: ClipboardItem) {
        ignoringNextCapture = true
        pasteboard.clearContents()
        switch item.kind {
        case .text, .link:
            if let text = item.text {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            if let path = item.imagePath,
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            }
        case .video, .file:
            if let url = item.fileURL as NSURL? {
                pasteboard.writeObjects([url])
            }
        }
        lastChangeCount = pasteboard.changeCount
    }

    private func captureCurrent() -> ClipboardItem? {
        if isSensitivePasteboard() { return nil }

        let source = NSWorkspace.shared.frontmostApplication?.localizedName

        // File URLs (video / generic file)
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], let url = urls.first {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > settings.maxMediaBytes { return nil }
            if isVideoURL(url) {
                return ClipboardItem(
                    id: UUID(),
                    kind: .video,
                    createdAt: Date(),
                    preview: url.lastPathComponent,
                    detail: byteSizeLabel(size),
                    text: nil,
                    imagePath: nil,
                    fileURL: url,
                    sourceApp: source,
                    byteSize: size,
                    contentKey: "video:\(url.path)",
                    pinned: false
                )
            }
            return ClipboardItem(
                id: UUID(),
                kind: .file,
                createdAt: Date(),
                preview: url.lastPathComponent,
                detail: byteSizeLabel(size),
                text: nil,
                imagePath: nil,
                fileURL: url,
                sourceApp: source,
                byteSize: size,
                contentKey: "file:\(url.path)",
                pinned: false
            )
        }

        // Public URL on pasteboard (not file)
        if let urlString = pasteboard.string(forType: .URL)
            ?? pasteboard.string(forType: NSPasteboard.PasteboardType("public.url")),
           let url = URL(string: urlString),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return makeLinkItem(url: url, source: source)
        }

        if let image = NSImage(pasteboard: pasteboard), image.isValid,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            let w = rep.pixelsWide
            let h = rep.pixelsHigh
            let png = rep.representation(using: .png, properties: [:])
            let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
            let data: Data
            let ext: String
            if let png, png.count <= settings.maxMediaBytes {
                data = png
                ext = "png"
            } else if let jpeg, jpeg.count <= settings.maxMediaBytes {
                data = jpeg
                ext = "jpg"
            } else if jpeg != nil {
                // Still over limit — keep a downscaled thumbnail only.
                let thumb = downscale(rep, maxEdge: 640)
                guard let small = thumb?.representation(using: .jpeg, properties: [.compressionFactor: 0.7]),
                      small.count <= settings.maxMediaBytes
                else { return nil }
                data = small
                ext = "jpg"
            } else {
                return nil
            }
            let path = saveMediaData(data, ext: ext)
            let preview = PluginL10n.tf(
                "plugin.clipboard.preview.image_size",
                locale: localeCode(),
                w, h
            )
            return ClipboardItem(
                id: UUID(),
                kind: .image,
                createdAt: Date(),
                preview: preview,
                detail: byteSizeLabel(data.count),
                text: nil,
                imagePath: path,
                fileURL: nil,
                sourceApp: source,
                byteSize: data.count,
                contentKey: "image:\(data.count):\(w)x\(h):\(data.prefix(64).base64EncodedString())",
                pinned: false
            )
        }

        if let text = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let clipped = text.count > Self.maxTextChars
                ? String(text.prefix(Self.maxTextChars))
                : text
            if looksLikeURL(clipped), let url = URL(string: clipped),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                return makeLinkItem(url: url, source: source)
            }
            let preview = multilinePreview(clipped)
            return ClipboardItem(
                id: UUID(),
                kind: .text,
                createdAt: Date(),
                preview: preview,
                detail: clipped.count > 80
                    ? PluginL10n.tf("plugin.clipboard.preview.chars", locale: localeCode(), clipped.count)
                    : nil,
                text: clipped,
                imagePath: nil,
                fileURL: nil,
                sourceApp: source,
                byteSize: clipped.utf8.count,
                contentKey: "text:\(clipped)",
                pinned: false
            )
        }

        return nil
    }

    private func makeLinkItem(url: URL, source: String?) -> ClipboardItem {
        let host = url.host ?? url.absoluteString
        return ClipboardItem(
            id: UUID(),
            kind: .link,
            createdAt: Date(),
            preview: url.absoluteString,
            detail: host,
            text: url.absoluteString,
            imagePath: nil,
            fileURL: url,
            sourceApp: source,
            byteSize: url.absoluteString.utf8.count,
            contentKey: "link:\(url.absoluteString)",
            pinned: false
        )
    }

    private func insert(_ item: ClipboardItem) {
        lock.lock()
        if let idx = items.firstIndex(where: { $0.contentKey == item.contentKey }) {
            let existing = items.remove(at: idx)
            // Refresh timestamp; keep pin + id/media.
            let refreshed = ClipboardItem(
                id: existing.id,
                kind: existing.kind,
                createdAt: Date(),
                preview: item.preview,
                detail: item.detail ?? existing.detail,
                text: existing.text ?? item.text,
                imagePath: existing.imagePath ?? item.imagePath,
                fileURL: existing.fileURL ?? item.fileURL,
                sourceApp: item.sourceApp ?? existing.sourceApp,
                byteSize: item.byteSize ?? existing.byteSize,
                contentKey: existing.contentKey,
                pinned: existing.pinned
            )
            // Drop newly saved media if we kept the old path.
            if let newPath = item.imagePath, newPath != refreshed.imagePath {
                try? FileManager.default.removeItem(atPath: newPath)
            }
            items.insert(refreshed, at: 0)
            sortItemsLocked()
            trimLocked()
            lock.unlock()
            persistHistory()
            objectWillChange.send()
            onChange?()
            return
        }
        items.insert(item, at: 0)
        sortItemsLocked()
        trimLocked()
        lock.unlock()
        persistHistory()
        objectWillChange.send()
        onChange?()
    }

    private func sortItemsLocked() {
        items.sort { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.createdAt > b.createdAt
        }
    }

    private func trimToMax() {
        lock.lock()
        trimLocked()
        lock.unlock()
        persistHistory()
    }

    private func trimLocked() {
        let limit = settings.maxItems
        guard limit > 0, items.count > limit else { return }
        var kept: [ClipboardItem] = []
        var removed: [ClipboardItem] = []
        for item in items {
            if item.pinned || kept.count < limit {
                kept.append(item)
            } else {
                removed.append(item)
            }
        }
        if kept.count > limit {
            let overflow = kept.filter { !$0.pinned }
            let drop = Swift.max(0, kept.count - limit)
            if drop > 0 {
                let toDrop = Array(overflow.suffix(drop))
                kept.removeAll { item in toDrop.contains(where: { $0.id == item.id }) }
                removed.append(contentsOf: toDrop)
            }
        }
        items = kept
        for item in removed { removeMedia(for: item) }
    }

    // MARK: - Helpers

    private func isSensitivePasteboard() -> Bool {
        let markers: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
            NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
            NSPasteboard.PasteboardType("com.apple.is-remote-clipboard")
        ]
        guard let types = pasteboard.types else { return false }
        return types.contains(where: { markers.contains($0) })
    }

    private func looksLikeURL(_ text: String) -> Bool {
        guard !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return false }
        return text.hasPrefix("http://") || text.hasPrefix("https://")
    }

    private func multilinePreview(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let head = lines.prefix(3).joined(separator: "\n")
        if head.count > 120 {
            return String(head.prefix(120)) + "…"
        }
        if lines.count > 3 { return head + "…" }
        return head
    }

    private func isVideoURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let videoExts: Set<String> = [
            "mp4", "mov", "m4v", "avi", "mkv", "webm", "mpeg", "mpg"
        ]
        if videoExts.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .movie) {
            return true
        }
        return false
    }

    private func byteSizeLabel(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    private func downscale(_ rep: NSBitmapImageRep, maxEdge: CGFloat) -> NSBitmapImageRep? {
        let w = CGFloat(rep.pixelsWide)
        let h = CGFloat(rep.pixelsHigh)
        let scale = min(1, maxEdge / max(w, h))
        if scale >= 0.999 { return rep }
        let size = NSSize(width: w * scale, height: h * scale)
        let image = NSImage(size: size)
        image.lockFocus()
        rep.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    private var mediaDir: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alwm/plugins/clipboard-media", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func saveMediaData(_ data: Data, ext: String) -> String {
        let url = mediaDir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try? data.write(to: url, options: .atomic)
        return url.path
    }

    private func removeMedia(for item: ClipboardItem) {
        if let path = item.imagePath {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private var settingsURL: URL {
        clipboardRoot.appendingPathComponent("settings.json")
    }

    private var historyURL: URL {
        clipboardRoot.appendingPathComponent("history.json")
    }

    private var legacySettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alwm/plugins/dev.alwm.clipboard.json")
    }

    private var legacyHistoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alwm/plugins/dev.alwm.clipboard.history.json")
    }

    private var clipboardRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alwm/clipboard", isDirectory: true)
    }

    private func loadSettings() {
        let urls = [settingsURL, legacySettingsURL]
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode(ClipboardSettings.self, from: data)
            else { continue }
            settings = decoded
            if settings.maxItems < 0 {
                settings.maxItems = 0
            } else if settings.maxItems > 0 {
                let snapped = Int((Double(settings.maxItems) / 10.0).rounded()) * 10
                settings.maxItems = min(200, max(10, snapped))
            }
            return
        }
    }

    private func saveSettings() {
        try? FileManager.default.createDirectory(
            at: clipboardRoot,
            withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: settingsURL, options: .atomic)
        // Keep legacy path updated for older builds.
        try? data.write(to: legacySettingsURL, options: .atomic)
    }

    private struct PersistedItem: Codable {
        var id: UUID
        var kind: ClipboardKind
        var createdAt: Date
        var preview: String
        var detail: String?
        var text: String?
        var imagePath: String?
        var fileURL: URL?
        var sourceApp: String?
        var byteSize: Int?
        var contentKey: String?
        var pinned: Bool
    }

    private func persistHistory() {
        lock.lock()
        let snapshot = items
        lock.unlock()
        let payload = snapshot.map {
            PersistedItem(
                id: $0.id,
                kind: $0.kind,
                createdAt: $0.createdAt,
                preview: $0.preview,
                detail: $0.detail,
                text: $0.text,
                imagePath: $0.imagePath,
                fileURL: $0.fileURL,
                sourceApp: $0.sourceApp,
                byteSize: $0.byteSize,
                contentKey: $0.contentKey,
                pinned: $0.pinned
            )
        }
        try? FileManager.default.createDirectory(
            at: clipboardRoot,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        // Write primary + legacy + backup so quit/repackage cannot wipe history.
        try? data.write(to: historyURL, options: .atomic)
        try? data.write(to: legacyHistoryURL, options: .atomic)
        try? data.write(
            to: clipboardRoot.appendingPathComponent("history.backup.json"),
            options: .atomic
        )
    }

    private func loadHistory() {
        let candidates = [
            historyURL,
            clipboardRoot.appendingPathComponent("history.backup.json"),
            legacyHistoryURL,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/alwm/plugins/dev.alwm.clipboard.pins.json")
        ]
        var decoded: [PersistedItem]?
        for url in candidates {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            if let rows = try? JSONDecoder().decode([PersistedItem].self, from: data) {
                decoded = rows
                break
            }
        }
        guard let decoded else { return }

        let fm = FileManager.default
        lock.lock()
        items = decoded.compactMap { row in
            // Keep text/link even if an old image file vanished; only drop pure media
            // entries whose backing file is gone and that have no text fallback.
            if let path = row.imagePath, !fm.fileExists(atPath: path) {
                if row.text == nil, row.kind == .image || row.kind == .video {
                    return nil
                }
            }
            let key = row.contentKey ?? "\(row.kind.rawValue):\(row.id.uuidString)"
            return ClipboardItem(
                id: row.id,
                kind: row.kind,
                createdAt: row.createdAt,
                preview: row.preview,
                detail: row.detail,
                text: row.text,
                imagePath: (row.imagePath).flatMap { fm.fileExists(atPath: $0) ? $0 : nil },
                fileURL: row.fileURL,
                sourceApp: row.sourceApp,
                byteSize: row.byteSize,
                contentKey: key,
                pinned: row.pinned
            )
        }
        sortItemsLocked()
        trimLocked()
        selectedID = items.first?.id
        lock.unlock()
        // Migrate into the stable location immediately.
        persistHistory()
        objectWillChange.send()
        onChange?()
    }
}
