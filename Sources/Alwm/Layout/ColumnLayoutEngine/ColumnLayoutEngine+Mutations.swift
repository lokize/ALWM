import Foundation

/// Pure layout engine: Niri-style scrolling columns. No AX / AppKit.

// MARK: - Column layout — insert/remove/rebalance

extension ColumnLayoutEngine {

    public func insertWindow(_ id: WindowID, into workspace: inout WorkspaceState, usable: Rect) {
        if let existing = locate(id, in: workspace) {
            workspace.focusedColumn = existing.col
            workspace.focusedWindowInColumn[existing.col] = existing.row
            return
        }
        let width = defaultColumnWidth(usable: usable, columnCount: max(1, workspace.columns.count))
        if workspace.columns.isEmpty {
            workspace.columns = [Column(windows: [id], width: width)]
            workspace.focusedColumn = 0
            workspace.focusedWindowInColumn[0] = 0
        } else {
            let col = min(max(0, workspace.focusedColumn), workspace.columns.count - 1)
            workspace.columns[col].windows.append(id)
            workspace.focusedWindowInColumn[col] = workspace.columns[col].windows.count - 1
            workspace.focusedColumn = col
        }
        snapViewToFocusedColumn(&workspace, usableWidth: usable.width)
    }


    /// Cross-workspace send: add a side-by-side column without stacking into the focused one.
    public func insertWindowAsNewColumn(_ id: WindowID, into workspace: inout WorkspaceState, usable: Rect) {
        if let existing = locate(id, in: workspace) {
            workspace.focusedColumn = existing.col
            workspace.focusedWindowInColumn[existing.col] = existing.row
            return
        }
        let count = workspace.columns.count + 1
        let width = defaultColumnWidth(usable: usable, columnCount: count)
        workspace.columns.append(Column(windows: [id], width: width))
        workspace.focusedColumn = workspace.columns.count - 1
        workspace.focusedWindowInColumn[workspace.focusedColumn] = 0
        ensureColumnWidths(workspace: &workspace, usable: usable)
        if contentWidth(workspace: workspace, usable: usable) > usable.width + 1.0 {
            fitAllColumnsOnScreen(workspace: &workspace, usable: usable)
        } else {
            snapViewToFocusedColumn(&workspace, usableWidth: usable.width)
        }
    }


    /// Shrink columns so the full row fits on screen (send-to-workspace must not scroll others away).
    public func fitAllColumnsOnScreen(workspace: inout WorkspaceState, usable: Rect, equalSplit: Bool = false) {
        guard !workspace.columns.isEmpty else {
            workspace.viewOffset = 0
            return
        }
        if equalSplit {
            rebalanceColumnsEqually(workspace: &workspace, usable: usable)
        } else {
            normalizeWidthsToFill(workspace: &workspace, usable: usable)
        }
        workspace.viewOffset = 0
    }


    /// Equal-width columns — used when a cross-workspace send adds a column (old ratios must not stick).
    public func rebalanceColumnsEqually(workspace: inout WorkspaceState, usable: Rect) {
        let n = workspace.columns.count
        guard n >= 1 else { return }
        let budget = fillWidthBudget(columnCount: n, usable: usable)
        let minW = settings.minColumnWidth
        let equal = max(minW, budget / Double(n))
        for i in workspace.columns.indices {
            workspace.columns[i].isMaximized = false
            workspace.columns[i].restoreWidth = 0
            workspace.columns[i].width = equal
        }
        var sum = workspace.columns.reduce(0.0) { $0 + $1.width }
        if let last = workspace.columns.indices.last {
            workspace.columns[last].width = max(minW, workspace.columns[last].width + (budget - sum))
        }
    }


    public func removeWindow(_ id: WindowID, from workspace: inout WorkspaceState) {
        guard let (col, row) = locate(id, in: workspace) else { return }
        workspace.columns[col].windows.remove(at: row)
        workspace.leafWeights.removeValue(forKey: id.token)
        if let fr = workspace.focusedWindowInColumn[col], fr >= workspace.columns[col].windows.count {
            workspace.focusedWindowInColumn[col] = max(0, workspace.columns[col].windows.count - 1)
        }
        cleanupEmptyColumns(&workspace)
        if workspace.focusedColumn >= workspace.columns.count {
            workspace.focusedColumn = max(0, workspace.columns.count - 1)
        }
    }


    /// After inserting a column, shift focus-map keys at/after the insert index (bounds-safe).
    func shiftFocusMapAfterInsert(at insertIndex: Int, workspace: inout WorkspaceState) {
        var shifted: [Int: Int] = [:]
        for (oldIdx, rowVal) in workspace.focusedWindowInColumn {
            let newIdx = oldIdx >= insertIndex ? oldIdx + 1 : oldIdx
            guard newIdx < workspace.columns.count else { continue }
            let maxRow = max(0, workspace.columns[newIdx].windows.count - 1)
            shifted[newIdx] = min(max(0, rowVal), maxRow)
        }
        workspace.focusedWindowInColumn = shifted
        if workspace.focusedColumn >= insertIndex {
            workspace.focusedColumn = min(workspace.focusedColumn + 1, max(0, workspace.columns.count - 1))
        }
    }


    func cleanupEmptyColumns(_ workspace: inout WorkspaceState) {
        let oldFocused = workspace.focusedWindowID
        var nextFocus: [Int: Int] = [:]
        var newColumns: [Column] = []
        for (oldIdx, column) in workspace.columns.enumerated() {
            guard !column.windows.isEmpty else { continue }
            let newIdx = newColumns.count
            if let row = workspace.focusedWindowInColumn[oldIdx] {
                nextFocus[newIdx] = min(max(0, row), max(0, column.windows.count - 1))
            }
            newColumns.append(column)
        }
        workspace.columns = newColumns
        workspace.focusedWindowInColumn = nextFocus
        if let oldFocused, let loc = locate(oldFocused, in: workspace) {
            workspace.focusedColumn = loc.col
            workspace.focusedWindowInColumn[loc.col] = loc.row
        } else if workspace.focusedColumn >= workspace.columns.count {
            workspace.focusedColumn = max(0, workspace.columns.count - 1)
        }
    }
}
