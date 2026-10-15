import Foundation

public enum WindowActionKind: String, Codable, Sendable {
    case move
    case resize
    case workspaceChange
    case close
}

public struct WindowActionHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: WindowActionKind
    public let timestamp: Date
    public let summary: String
    public let targetBundleID: String?
    public let targetWorkspaceID: String?
    public let before: RuntimeStateStore.Snapshot
    public let after: RuntimeStateStore.Snapshot

    public init(
        id: UUID = UUID(),
        kind: WindowActionKind,
        timestamp: Date = Date(),
        summary: String,
        targetBundleID: String? = nil,
        targetWorkspaceID: String? = nil,
        before: RuntimeStateStore.Snapshot,
        after: RuntimeStateStore.Snapshot
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.summary = summary
        self.targetBundleID = targetBundleID
        self.targetWorkspaceID = targetWorkspaceID
        self.before = before
        self.after = after
    }
}

/// Bounded session history; it stores ALWM placement only and never intercepts app Cmd-Z.
public final class WindowActionHistory {
    public let capacity: Int
    public private(set) var entries: [WindowActionHistoryEntry] = []
    private let url: URL

    public init(
        capacity: Int = 20,
        url: URL = ConfigPaths.root.appendingPathComponent("window-history.json")
    ) {
        self.capacity = max(1, capacity)
        self.url = url
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([WindowActionHistoryEntry].self, from: data) {
            entries = Array(saved.suffix(self.capacity))
        }
    }

    public func append(_ entry: WindowActionHistoryEntry) {
        guard entry.before != entry.after || entry.kind == .close else { return }
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        save()
    }

    public func popLast() -> WindowActionHistoryEntry? {
        guard !entries.isEmpty else { return nil }
        let entry = entries.removeLast()
        save()
        return entry
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(entries).write(to: url, options: .atomic)
        } catch {
            NSLog("ALWM: window history save failed: %@", error.localizedDescription)
        }
    }
}
