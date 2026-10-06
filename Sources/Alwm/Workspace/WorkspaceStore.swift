import AppKit
import Foundation

public struct MonitorInfo: Equatable, Sendable {
    public var id: CGDirectDisplayID
    /// Full display bounds in AX (top-left) coordinates.
    public var frame: Rect
    /// Area free of the menu bar / dock — use this for tiling usable area.
    public var visibleFrame: Rect
    public var name: String

    public init(id: CGDirectDisplayID, frame: Rect, visibleFrame: Rect, name: String) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.name = name
    }

    /// Layout canvas: visible area (menu bar / dock already excluded).
    public var layoutFrame: Rect { visibleFrame }
}

public final class MonitorStore: @unchecked Sendable {
    public private(set) var monitors: [MonitorInfo] = []
    public var onChange: (() -> Void)?
    private var refreshWorkItem: DispatchWorkItem?

    public init(monitors: [MonitorInfo] = []) { self.monitors = monitors }

    public func refresh() {
        var result: [MonitorInfo] = []
        for screen in NSScreen.screens {
            let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let id = CGDirectDisplayID(num?.uint32Value ?? 0)
            let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            func axRect(_ f: NSRect) -> Rect {
                Rect(
                    x: f.origin.x,
                    y: mainHeight - f.origin.y - f.height,
                    width: f.width,
                    height: f.height
                )
            }
            result.append(
                MonitorInfo(
                    id: id,
                    frame: axRect(screen.frame),
                    visibleFrame: axRect(screen.visibleFrame),
                    name: screen.localizedName
                )
            )
        }
        monitors = result
        onChange?()
    }

    public func monitorContaining(pointX: Double, pointY: Double) -> MonitorInfo? {
        monitors.first { $0.frame.contains(pointX: pointX, pointY: pointY) } ?? monitors.first
    }

    public func startObserving() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh()
        }
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refresh()
        }
        refreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

public final class WorkspaceStore: @unchecked Sendable {
    /// monitorID -> active workspace id
    public private(set) var activeWorkspaceByMonitor: [CGDirectDisplayID: String] = [:]
    /// Keep a temporary display's selection while macOS removes it during sleep or hotplug.
    private var detachedWorkspaceByMonitor: [CGDirectDisplayID: String] = [:]
    /// workspace id -> state (shared across monitors for simplicity; each monitor tracks its own active id)
    public private(set) var workspaces: [String: WorkspaceState] = [:]
    public private(set) var definitions: [WorkspaceDefinition] = []
    private var connectedMonitorCount = 0
    /// Logical slots stay attached to display IDs when NSScreen reorders its array.
    private var logicalMonitorIndexByID: [CGDirectDisplayID: Int] = [:]

    public init() {}

    /// Dwindle expects one window per column (BSP leaves). Niri may stack many per column.
    private static func normalizeColumns(for workspace: inout WorkspaceState) {
        guard workspace.layout == .dwindle else { return }
        let focused = workspace.focusedWindowID
        let order = workspace.orderedWindowIDs
        workspace.columns = order.map { Column(windows: [$0], width: 0) }
        if let focused {
            for (c, col) in workspace.columns.enumerated() where col.windows.contains(focused) {
                workspace.focusedColumn = c
                workspace.focusedWindowInColumn[c] = 0
                return
            }
        }
        workspace.focusedColumn = 0
        if !workspace.columns.isEmpty {
            workspace.focusedWindowInColumn[0] = 0
        }
    }

    public func configure(
        definitions: [WorkspaceDefinition],
        monitors: [MonitorInfo],
        savedWorkspaceByMonitor: [CGDirectDisplayID: String] = [:],
        savedMonitorIndexByID: [CGDirectDisplayID: Int] = [:]
    ) {
        self.definitions = definitions
        connectedMonitorCount = monitors.count
        for (id, index) in savedMonitorIndexByID where logicalMonitorIndexByID[id] == nil {
            logicalMonitorIndexByID[id] = index
        }
        assignLogicalMonitorIndices(for: monitors)
        var next: [String: WorkspaceState] = [:]
        for def in definitions {
            if let existing = workspaces[def.id] {
                var updated = existing
                let layoutChanged = updated.layout != def.layout
                updated.name = def.name
                updated.layout = def.layout
                if layoutChanged || updated.layout == .dwindle {
                    Self.normalizeColumns(for: &updated)
                }
                next[def.id] = updated
            } else {
                next[def.id] = WorkspaceState(id: def.id, name: def.name, layout: def.layout)
            }
        }
        workspaces = next

        let live = Set(monitors.map(\.id))
        for (monitorID, workspaceID) in activeWorkspaceByMonitor where !live.contains(monitorID) {
            detachedWorkspaceByMonitor[monitorID] = workspaceID
        }
        activeWorkspaceByMonitor = activeWorkspaceByMonitor.filter { live.contains($0.key) }

        // Each monitor keeps (or picks) an active workspace from its own pool only.
        for mon in monitors {
            let idx = monitorIndex(of: mon.id, in: monitors) ?? 0
            let pool = definitionsVisible(onMonitorIndex: idx).map(\.id)
            let remembered = detachedWorkspaceByMonitor.removeValue(forKey: mon.id)
            if let current = activeWorkspaceByMonitor[mon.id],
               pool.contains(current),
               workspaces[current] != nil {
                continue
            }
            let saved = savedWorkspaceByMonitor[mon.id]
            let pick = [remembered, saved].compactMap { $0 }
                .first(where: { pool.contains($0) && workspaces[$0] != nil })
                ?? pool.first(where: { workspaces[$0] != nil })
            if let pick {
                activeWorkspaceByMonitor[mon.id] = pick
            } else {
                activeWorkspaceByMonitor.removeValue(forKey: mon.id)
            }
        }
    }

    /// Monitor that should show this workspace (pinned), if any.
    public func preferredMonitor(
        forWorkspace workspaceID: String,
        monitors: [MonitorInfo]
    ) -> MonitorInfo? {
        guard let def = definitions.first(where: { $0.id == workspaceID }) else { return nil }
        // In clamshell mode every workspace is available on the sole display.
        if monitors.count == 1 { return monitors[0] }
        guard let idx = def.monitorIndex else { return nil }
        return monitors.first { monitorIndex(of: $0.id, in: monitors) == idx }
    }

    /// Workspaces that belong on this monitor index.
    /// - Pinned (`monitorIndex == idx`): only that monitor.
    /// - Auto (`nil`): treated as primary monitor (index 0) only.
    ///   Secondary displays never inherit Auto workspaces — pin them explicitly.
    /// - With one connected display, all workspaces remain reachable there.
    public func definitionsVisible(onMonitorIndex idx: Int) -> [WorkspaceDefinition] {
        Self.definitions(
            definitions,
            visibleOnMonitorIndex: idx,
            connectedMonitorCount: connectedMonitorCount
        )
    }

    public static func definitions(
        _ definitions: [WorkspaceDefinition],
        visibleOnMonitorIndex idx: Int,
        connectedMonitorCount: Int? = nil
    ) -> [WorkspaceDefinition] {
        if connectedMonitorCount == 1, idx == 0 { return definitions }
        return definitions.filter { def in
            let pin = def.monitorIndex ?? 0
            return pin == idx
        }
    }

    public func isWorkspace(_ workspaceID: String, allowedOnMonitorIndex idx: Int) -> Bool {
        definitionsVisible(onMonitorIndex: idx).contains { $0.id == workspaceID }
    }

    /// Index of `monitor` in `monitors`, or nil if missing.
    public func monitorIndex(of monitorID: CGDirectDisplayID, in monitors: [MonitorInfo]) -> Int? {
        guard monitors.contains(where: { $0.id == monitorID }) else { return nil }
        // In clamshell mode the sole display is the only logical slot, even if it
        // was previously the secondary display while another monitor was connected.
        if monitors.count == 1 { return 0 }
        return logicalMonitorIndexByID[monitorID]
            ?? monitors.firstIndex(where: { $0.id == monitorID })
    }

    /// Stable logical slots used by switching, assignment, and the workspace bar.
    public func logicalMonitorIndices(for monitors: [MonitorInfo]) -> [CGDirectDisplayID: Int] {
        Dictionary(uniqueKeysWithValues: monitors.compactMap { monitor in
            monitorIndex(of: monitor.id, in: monitors).map { (monitor.id, $0) }
        })
    }

    private func assignLogicalMonitorIndices(for monitors: [MonitorInfo]) {
        var used = Set(logicalMonitorIndexByID.values)
        for (currentIndex, monitor) in monitors.enumerated() {
            if logicalMonitorIndexByID[monitor.id] != nil { continue }
            let slot: Int
            if !used.contains(currentIndex) {
                slot = currentIndex
            } else {
                slot = (0...max(currentIndex, monitors.count)).first(where: { !used.contains($0) })
                    ?? currentIndex
            }
            logicalMonitorIndexByID[monitor.id] = slot
            used.insert(slot)
        }
    }

    /// Switch the active workspace on one monitor.
    /// Other monitors keep their own active workspace (unless this id was exclusive there).
    public func switchWorkspace(
        id: String,
        on monitor: CGDirectDisplayID,
        monitors: [MonitorInfo],
        syncAllMonitors: Bool = false
    ) {
        guard workspaces[id] != nil else { return }
        if let idx = monitorIndex(of: monitor, in: monitors),
           !isWorkspace(id, allowedOnMonitorIndex: idx) {
            return
        }

        if syncAllMonitors {
            for mon in monitors {
                if let idx = monitorIndex(of: mon.id, in: monitors),
                   isWorkspace(id, allowedOnMonitorIndex: idx) {
                    activeWorkspaceByMonitor[mon.id] = id
                }
            }
            activeWorkspaceByMonitor[monitor] = id
            return
        }

        // Per-monitor: if another display was showing this same workspace and it is not
        // allowed to keep it in parallel, give that display a fallback from its pool.
        for mon in monitors where mon.id != monitor {
            guard activeWorkspaceByMonitor[mon.id] == id else { continue }
            guard let monIdx = monitorIndex(of: mon.id, in: monitors) else { continue }
            // Same workspace can stay active on multiple displays only when both
            // monitors list it (rare). Otherwise steal and fall back.
            let pool = definitionsVisible(onMonitorIndex: monIdx).map(\.id)
            if pool.contains(id) { continue }
            let fallback = pool.first(where: { $0 != id && workspaces[$0] != nil })
                ?? pool.first
            if let fallback, fallback != id {
                activeWorkspaceByMonitor[mon.id] = fallback
            }
        }
        activeWorkspaceByMonitor[monitor] = id
    }

    public func activeWorkspace(for monitor: CGDirectDisplayID) -> WorkspaceState? {
        guard let id = activeWorkspaceByMonitor[monitor] else { return nil }
        return workspaces[id]
    }

    public func updateActiveWorkspace(for monitor: CGDirectDisplayID, _ mutate: (inout WorkspaceState) -> Void) {
        guard let id = activeWorkspaceByMonitor[monitor], var ws = workspaces[id] else { return }
        mutate(&ws)
        workspaces[id] = ws
    }

    public func setWorkspace(_ state: WorkspaceState) {
        workspaces[state.id] = state
    }

    public func workspaceID(containing window: WindowID) -> String? {
        for (id, ws) in workspaces {
            if ws.columns.contains(where: { $0.windows.contains(window) }) {
                return id
            }
        }
        return nil
    }

    public func removeWindowEverywhere(_ id: WindowID) {
        for key in workspaces.keys {
            var ws = workspaces[key]!
            for c in ws.columns.indices {
                ws.columns[c].windows.removeAll { $0 == id }
            }
            ws.columns.removeAll { $0.windows.isEmpty }
            workspaces[key] = ws
        }
    }

    public func insert(
        _ windowID: WindowID,
        into workspaceID: String,
        using insert: (inout WorkspaceState) -> Void
    ) {
        guard var ws = workspaces[workspaceID] else { return }
        removeWindowEverywhere(windowID)
        insert(&ws)
        workspaces[workspaceID] = ws
    }
}
