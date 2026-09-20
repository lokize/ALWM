import AppKit
import Foundation
import AlwmL10n

struct FolderStats: Equatable, Sendable {
    var itemCount: Int = 0
    var byteSize: Int64 = 0

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

enum DownloadsAgeDays: Int, CaseIterable, Identifiable, Sendable {
    case seven = 7
    case fourteen = 14
    case thirty = 30
    case ninety = 90

    var id: Int { rawValue }
}

final class DownloadsStore: ObservableObject, @unchecked Sendable {
    static let shared = DownloadsStore()

    @Published private(set) var downloads = FolderStats()
    @Published private(set) var trash = FolderStats()
    @Published private(set) var oldDownloadsCount = 0
    @Published private(set) var oldDownloadsBytes: Int64 = 0
    @Published private(set) var isRefreshing = false
    @Published private(set) var isCleaning = false
    @Published var lastError: String?
    @Published var statusLine = ""
    @Published var ageDays: DownloadsAgeDays = .thirty

    var localeCode: () -> String = { PluginL10n.currentCode }
    var onChange: (() -> Void)?

    private var refreshTimer: Timer?
    private let defaultsKey = "dev.alwm.downloads.ageDays"

    private init() {
        let saved = UserDefaults.standard.integer(forKey: defaultsKey)
        if let age = DownloadsAgeDays(rawValue: saved) {
            ageDays = age
        }
    }

    var barLabel: String {
        "\(downloads.itemCount)"
    }

    var barTint: NSColor {
        if downloads.itemCount > 50 || trash.itemCount > 20 {
            return .systemOrange
        }
        return .labelColor
    }

    var tooltip: String {
        let loc = localeCode()
        return PluginL10n.tf(
            "plugin.downloads.tooltip",
            locale: loc,
            downloads.itemCount,
            trash.itemCount
        )
    }

    var downloadsURL: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    var trashURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
    }

    func start() {
        if refreshTimer == nil {
            let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                Task { await self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            refreshTimer = t
        }
        Task { await refresh() }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func setAgeDays(_ days: DownloadsAgeDays) {
        ageDays = days
        UserDefaults.standard.set(days.rawValue, forKey: defaultsKey)
        Task { await refresh() }
    }

    func refresh() async {
        await MainActor.run {
            isRefreshing = true
            lastError = nil
            objectWillChange.send()
        }

        let dlURL = downloadsURL
        let trURL = trashURL
        let cutoff = Date().addingTimeInterval(-TimeInterval(ageDays.rawValue) * 24 * 3600)

        let result = await Task.detached(priority: .utility) { () -> (FolderStats, FolderStats, Int, Int64) in
            let dl = Self.scanFolder(dlURL)
            let tr = Self.scanFolder(trURL)
            let old = Self.countOlder(than: cutoff, in: dlURL)
            return (dl, tr, old.count, old.bytes)
        }.value

        await MainActor.run {
            downloads = result.0
            trash = result.1
            oldDownloadsCount = result.2
            oldDownloadsBytes = result.3
            isRefreshing = false
            objectWillChange.send()
            onChange?()
        }
    }

    func cleanOldDownloads() async {
        let loc = localeCode()
        await MainActor.run {
            isCleaning = true
            statusLine = PluginL10n.t("plugin.downloads.status.cleaning", locale: loc)
            lastError = nil
            objectWillChange.send()
        }

        let dlURL = downloadsURL
        let cutoff = Date().addingTimeInterval(-TimeInterval(ageDays.rawValue) * 24 * 3600)

        let outcome = await Task.detached(priority: .utility) { () -> (Int, String?) in
            do {
                let removed = try Self.removeOlder(than: cutoff, in: dlURL)
                return (removed, nil)
            } catch {
                return (0, error.localizedDescription)
            }
        }.value

        await MainActor.run {
            isCleaning = false
            statusLine = ""
            if let err = outcome.1 {
                lastError = err
            } else {
                statusLine = PluginL10n.tf(
                    "plugin.downloads.status.cleaned",
                    locale: localeCode(),
                    outcome.0
                )
            }
            objectWillChange.send()
        }
        await refresh()
    }

    func emptyTrash() async {
        let loc = localeCode()
        await MainActor.run {
            isCleaning = true
            statusLine = PluginL10n.t("plugin.downloads.status.emptying", locale: loc)
            lastError = nil
            objectWillChange.send()
        }

        let trURL = trashURL
        let outcome = await Task.detached(priority: .utility) { () -> String? in
            do {
                try Self.emptyFolder(trURL)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value

        await MainActor.run {
            isCleaning = false
            statusLine = outcome == nil
                ? PluginL10n.t("plugin.downloads.status.emptied", locale: localeCode())
                : ""
            lastError = outcome
            objectWillChange.send()
        }
        await refresh()
    }

    func openDownloads() {
        NSWorkspace.shared.open(downloadsURL)
    }

    func openTrash() {
        // Reveal Trash in Finder via AppleScript-friendly path
        let script = """
        tell application "Finder"
            open trash
            activate
        end tell
        """
        if let apple = NSAppleScript(source: script) {
            var err: NSDictionary?
            apple.executeAndReturnError(&err)
            if err == nil { return }
        }
        NSWorkspace.shared.open(trashURL)
    }

    // MARK: - FS helpers

    private static func scanFolder(_ url: URL) -> FolderStats {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            return FolderStats()
        }
        var count = 0
        var bytes: Int64 = 0
        for item in items {
            count += 1
            bytes += fileSize(of: item)
        }
        return FolderStats(itemCount: count, byteSize: bytes)
    }

    private static func countOlder(than cutoff: Date, in url: URL) -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0)
        }
        var count = 0
        var bytes: Int64 = 0
        for item in items {
            let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let date = values?.contentModificationDate ?? values?.creationDate ?? Date.distantFuture
            if date < cutoff {
                count += 1
                bytes += fileSize(of: item)
            }
        }
        return (count, bytes)
    }

    private static func removeOlder(than cutoff: Date, in url: URL) throws -> Int {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        var removed = 0
        for item in items {
            let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let date = values?.contentModificationDate ?? values?.creationDate ?? Date.distantFuture
            guard date < cutoff else { continue }
            try fm.removeItem(at: item)
            removed += 1
        }
        return removed
    }

    private static func emptyFolder(_ url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let items = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )
        for item in items {
            try fm.removeItem(at: item)
        }
    }

    private static func fileSize(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if isDir.boolValue {
            // Approximate: sum immediate children only (fast enough for chip)
            guard let children = try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            var total: Int64 = 0
            for child in children {
                var childDir: ObjCBool = false
                if fm.fileExists(atPath: child.path, isDirectory: &childDir), childDir.boolValue {
                    continue
                }
                if let values = try? child.resourceValues(forKeys: [.fileSizeKey]),
                   let size = values.fileSize {
                    total += Int64(size)
                }
            }
            return total
        }
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            return Int64(size)
        }
        return 0
    }
}
