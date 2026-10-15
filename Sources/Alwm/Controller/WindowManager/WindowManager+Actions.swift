import AppKit
import Foundation

extension WindowManager {
    func rememberCurrentDisplayTopology() {
        guard !monitors.monitors.isEmpty else { return }
        displayTopologyProfiles.remember(
            monitors: monitors.monitors,
            activeWorkspaceByMonitor: workspaces.activeWorkspaceByMonitor,
            logicalIndexByMonitor: workspaces.logicalMonitorIndices(for: monitors.monitors)
        )
    }

    func toggleOverview() {
        guard let monitor = monitorForAction() ?? primaryMonitor() else { return }
        overview.toggle(
            monitor: monitor,
            definitions: configStore.config.workspaces,
            workspaces: workspaces.workspaces,
            windowsByID: windowsByID,
            mainHeight: Double(NSScreen.screens.first?.frame.height ?? CGFloat(monitor.frame.height)),
            savedLayouts: runtimeState.snapshot.workspaceLayouts
        )
    }

    func refreshOverview() {
        guard overview.isVisible else { return }
        overview.hide()
        toggleOverview()
    }

    @discardableResult
    func undoLastWindowAction() -> Bool {
        guard let entry = windowActionHistory.popLast() else { return false }
        runtimeState.replaceSnapshot(entry.before)
        if entry.kind == .close, let bundleID = entry.targetBundleID {
            openSessionApp(bundleID: bundleID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.ax.scanAll()
                self.ingest(windows: self.ax.currentWindows)
                self.runLayoutRecovery(force: true)
                self.forceRelayoutActiveWorkspaces()
                self.refreshChrome()
            }
            return true
        }
        runLayoutRecovery(force: true)
        forceRelayoutActiveWorkspaces()
        refreshChrome()
        return true
    }

    func overviewMoveWindow(_ id: WindowID, to workspaceID: String) {
        moveWindow(requestedID: id, to: workspaceID, follow: false)
        refreshOverview()
    }

    func overviewMoveWindow(_ id: WindowID, to workspaceID: String, columnIndex: Int) {
        guard var workspace = workspaces.workspaces[workspaceID] else { return }
        let before = runtimeState.snapshot
        performMoveWindow(requestedID: id, to: workspaceID, follow: false)
        guard let liveID = resolveLiveWindowID(for: id, preferredWS: workspaceID) else { return }
        guard var updated = workspaces.workspaces[workspaceID] else { return }
        for column in updated.columns.indices {
            updated.columns[column].windows.removeAll { $0 == liveID }
        }
        updated.columns.removeAll { $0.windows.isEmpty }
        let focusedColumn: Int
        let focusedRow: Int
        if updated.columns.isEmpty {
            updated.columns.append(Column(windows: [liveID], width: 0))
            focusedColumn = 0
            focusedRow = 0
        } else {
            let destination = min(max(0, columnIndex), updated.columns.count - 1)
            if updated.layout == .dwindle {
                updated.columns.insert(Column(windows: [liveID], width: 0), at: destination)
                focusedColumn = destination
                focusedRow = 0
            } else {
                updated.columns[destination].windows.append(liveID)
                focusedColumn = destination
                focusedRow = updated.columns[destination].windows.count - 1
            }
        }
        updated.focusedColumn = focusedColumn
        updated.focusedWindowInColumn[focusedColumn] = focusedRow
        workspace = updated
        workspaces.setWorkspace(workspace)
        persistRuntimeState(forceWorkspaceLayouts: [workspaceID])
        windowActionHistory.append(WindowActionHistoryEntry(
            kind: .move,
            summary: "Moved window into a column in workspace \(workspaceID)",
            targetWorkspaceID: workspaceID,
            before: before,
            after: runtimeState.snapshot
        ))
        if let monitor = workspaces.preferredMonitor(forWorkspace: workspaceID, monitors: monitors.monitors) {
            applyWorkspaceTileLayout(workspaceID, on: monitor, forceReveal: true, movedID: liveID)
        }
        refreshOverview()
    }

    func overviewCloseWindow(_ id: WindowID) {
        closeWindow(id)
        overview.hide()
    }

    func overviewReorderColumn(_ workspaceID: String, from source: Int, to destination: Int) {
        guard var workspace = workspaces.workspaces[workspaceID],
              workspace.columns.indices.contains(source),
              workspace.columns.indices.contains(destination),
              source != destination else { return }
        let before = runtimeState.snapshot
        let column = workspace.columns.remove(at: source)
        workspace.columns.insert(column, at: destination)
        workspace.focusedColumn = destination
        workspaces.setWorkspace(workspace)
        persistRuntimeState(forceWorkspaceLayouts: [workspaceID])
        windowActionHistory.append(WindowActionHistoryEntry(
            kind: .move,
            summary: "Reordered columns in workspace \(workspaceID)",
            targetWorkspaceID: workspaceID,
            before: before,
            after: runtimeState.snapshot
        ))
        if let monitor = workspaces.preferredMonitor(forWorkspace: workspaceID, monitors: monitors.monitors),
           isHomeActiveOnAnyMonitor(workspaceID) {
            applyWorkspaceTileLayout(workspaceID, on: monitor, forceReveal: true)
        }
        refreshOverview()
    }

    func overviewLaunchApp(bundleID: String, workspaceID: String) {
        guard !isSessionAppRunning(bundleID) else { return }
        openSessionApp(bundleID: bundleID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.ax.scanAll()
            self.ingest(windows: self.ax.currentWindows)
            if let window = self.windowsByID.values.first(where: { $0.bundleID == bundleID }) {
                self.moveWindow(requestedID: window.id, to: workspaceID)
            }
            self.refreshOverview()
        }
    }
}
