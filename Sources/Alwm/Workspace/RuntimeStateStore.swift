import CoreGraphics
import Foundation

/// Persists last-active workspaces, sticky assignments, and per-workspace window order across ALWM launches.
public final class RuntimeStateStore: @unchecked Sendable {
    /// Stable-enough identity for matching windows after ALWM restarts (tokens can change).
    public struct WindowRef: Codable, Equatable, Sendable {
        public var token: String
        public var bundleID: String?
        public var appName: String
        public var title: String

        public init(token: String, bundleID: String? = nil, appName: String = "", title: String = "") {
            self.token = token
            self.bundleID = bundleID
            self.appName = appName
            self.title = title
        }

        public init(window: ManagedWindow) {
            self.token = window.id.token
            self.bundleID = window.bundleID
            self.appName = window.appName
            self.title = window.title
        }
    }

    public struct ColumnSnapshot: Codable, Equatable, Sendable {
        public var windows: [WindowRef]
        public var width: Double
        public var isMaximized: Bool
        public var restoreWidth: Double

        enum CodingKeys: String, CodingKey { case windows, width, isMaximized, restoreWidth }

        public init(
            windows: [WindowRef] = [],
            width: Double = 0,
            isMaximized: Bool = false,
            restoreWidth: Double = 0
        ) {
            self.windows = windows
            self.width = width
            self.isMaximized = isMaximized
            self.restoreWidth = restoreWidth
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 0
            isMaximized = try c.decodeIfPresent(Bool.self, forKey: .isMaximized) ?? false
            restoreWidth = try c.decodeIfPresent(Double.self, forKey: .restoreWidth) ?? 0
            if let refs = try? c.decode([WindowRef].self, forKey: .windows) {
                windows = refs
            } else if let tokens = try? c.decode([String].self, forKey: .windows) {
                windows = tokens.map { WindowRef(token: $0) }
            } else {
                windows = []
            }
        }
    }

    public struct WorkspaceLayoutSnapshot: Codable, Equatable, Sendable {
        public var columns: [ColumnSnapshot]
        public var focusedColumn: Int
        /// String keys because JSON dictionaries require them.
        public var focusedWindowInColumn: [String: Int]
        public var viewOffset: Double
        public var leafWeights: [String: Double]
        public var floating: [WindowRef]

        enum CodingKeys: String, CodingKey {
            case columns, focusedColumn, focusedWindowInColumn, viewOffset, leafWeights, floating
        }

        public init(
            columns: [ColumnSnapshot] = [],
            focusedColumn: Int = 0,
            focusedWindowInColumn: [String: Int] = [:],
            viewOffset: Double = 0,
            leafWeights: [String: Double] = [:],
            floating: [WindowRef] = []
        ) {
            self.columns = columns
            self.focusedColumn = focusedColumn
            self.focusedWindowInColumn = focusedWindowInColumn
            self.viewOffset = viewOffset
            self.leafWeights = leafWeights
            self.floating = floating
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            columns = try c.decodeIfPresent([ColumnSnapshot].self, forKey: .columns) ?? []
            focusedColumn = try c.decodeIfPresent(Int.self, forKey: .focusedColumn) ?? 0
            focusedWindowInColumn = try c.decodeIfPresent([String: Int].self, forKey: .focusedWindowInColumn) ?? [:]
            viewOffset = try c.decodeIfPresent(Double.self, forKey: .viewOffset) ?? 0
            leafWeights = try c.decodeIfPresent([String: Double].self, forKey: .leafWeights) ?? [:]
            if let refs = try? c.decode([WindowRef].self, forKey: .floating) {
                floating = refs
            } else if let tokens = try? c.decode([String].self, forKey: .floating) {
                floating = tokens.map { WindowRef(token: $0) }
            } else {
                floating = []
            }
        }
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var lastWorkspaceByMonitor: [String: String]
        public var windowWorkspace: [String: String]
        /// bundleID → workspace id (survives window-number churn without app rules).
        public var bundleWorkspace: [String: String]
        public var lastWorkspace: String?
        public var workspaceLayouts: [String: WorkspaceLayoutSnapshot]
        /// Persisted Quake scratchpad window token (`pid:windowNumber`).
        public var quakeWindowToken: String?

        enum CodingKeys: String, CodingKey {
            case lastWorkspaceByMonitor, windowWorkspace, bundleWorkspace, lastWorkspace, workspaceLayouts
            case quakeWindowToken
        }

        public init(
            lastWorkspaceByMonitor: [String: String] = [:],
            windowWorkspace: [String: String] = [:],
            bundleWorkspace: [String: String] = [:],
            lastWorkspace: String? = nil,
            workspaceLayouts: [String: WorkspaceLayoutSnapshot] = [:],
            quakeWindowToken: String? = nil
        ) {
            self.lastWorkspaceByMonitor = lastWorkspaceByMonitor
            self.windowWorkspace = windowWorkspace
            self.bundleWorkspace = bundleWorkspace
            self.lastWorkspace = lastWorkspace
            self.workspaceLayouts = workspaceLayouts
            self.quakeWindowToken = quakeWindowToken
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            lastWorkspaceByMonitor = try c.decodeIfPresent([String: String].self, forKey: .lastWorkspaceByMonitor) ?? [:]
            windowWorkspace = try c.decodeIfPresent([String: String].self, forKey: .windowWorkspace) ?? [:]
            bundleWorkspace = try c.decodeIfPresent([String: String].self, forKey: .bundleWorkspace) ?? [:]
            lastWorkspace = try c.decodeIfPresent(String.self, forKey: .lastWorkspace)
            workspaceLayouts = try c.decodeIfPresent([String: WorkspaceLayoutSnapshot].self, forKey: .workspaceLayouts) ?? [:]
            quakeWindowToken = try c.decodeIfPresent(String.self, forKey: .quakeWindowToken)
        }
    }

    public private(set) var snapshot: Snapshot = Snapshot()
    private let url: URL

    public init(url: URL = ConfigPaths.runtimeState) {
        self.url = url
        load()
    }

    public func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            snapshot = Snapshot()
            return
        }
        snapshot = decoded
    }

    public func save() {
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let data = try enc.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("ALWM: failed to save runtime state: \(error)")
        }
    }

    public func clear() {
        snapshot = Snapshot()
        try? FileManager.default.removeItem(at: url)
    }

    public func assignment(for window: WindowID) -> String? {
        snapshot.windowWorkspace[window.token]
    }

    public func bundleAssignment(for bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return snapshot.bundleWorkspace[bundleID]
    }

    public func setAssignment(_ workspaceID: String?, for window: WindowID) {
        if let workspaceID {
            snapshot.windowWorkspace[window.token] = workspaceID
        } else {
            snapshot.windowWorkspace.removeValue(forKey: window.token)
        }
    }

    public func setBundleAssignment(_ workspaceID: String?, for bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        if let workspaceID {
            snapshot.bundleWorkspace[bundleID] = workspaceID
        } else {
            snapshot.bundleWorkspace.removeValue(forKey: bundleID)
        }
    }

    public func setLastWorkspace(_ workspaceID: String, on monitorID: CGDirectDisplayID) {
        snapshot.lastWorkspaceByMonitor[String(monitorID)] = workspaceID
        snapshot.lastWorkspace = workspaceID
    }

    public func setQuakeWindowToken(_ token: String?) {
        snapshot.quakeWindowToken = token
    }

    public func lastWorkspace(for monitorID: CGDirectDisplayID) -> String? {
        snapshot.lastWorkspaceByMonitor[String(monitorID)] ?? snapshot.lastWorkspace
    }

    public func setWorkspaceLayout(_ layout: WorkspaceLayoutSnapshot, for workspaceID: String) {
        snapshot.workspaceLayouts[workspaceID] = layout
    }

    public func workspaceLayout(for workspaceID: String) -> WorkspaceLayoutSnapshot? {
        snapshot.workspaceLayouts[workspaceID]
    }

    public func pruneWindows(keeping live: Set<WindowID>) {
        let liveTokens = Set(live.map(\.token))
        snapshot.windowWorkspace = snapshot.windowWorkspace.filter { liveTokens.contains($0.key) }
        for (wsID, var layout) in snapshot.workspaceLayouts {
            layout.columns = layout.columns.map { col in
                ColumnSnapshot(
                    windows: col.windows.filter { liveTokens.contains($0.token) || $0.bundleID != nil },
                    width: col.width,
                    isMaximized: col.isMaximized,
                    restoreWidth: col.restoreWidth
                )
            }
            layout.columns.removeAll { $0.windows.isEmpty }
            layout.floating = layout.floating.filter { liveTokens.contains($0.token) || $0.bundleID != nil }
            layout.leafWeights = layout.leafWeights.filter { liveTokens.contains($0.key) }
            snapshot.workspaceLayouts[wsID] = layout
        }
    }
}
