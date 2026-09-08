import Foundation

/// Pure layout engine: Niri-style scrolling columns. No AX / AppKit.

// MARK: - Column layout — focus navigation

extension ColumnLayoutEngine {

    public func focus(_ direction: Direction, workspace: inout WorkspaceState) {
        guard !workspace.columns.isEmpty else { return }
        // Stale focus (after column cleanup / restore) must not trap on columns[col].
        workspace.focusedColumn = min(max(0, workspace.focusedColumn), workspace.columns.count - 1)
        switch direction {
        case .left:
            var col = workspace.focusedColumn
            while col > 0 {
                col -= 1
                if !workspace.columns[col].windows.isEmpty {
                    workspace.focusedColumn = col
                    break
                }
            }
        case .right:
            var col = workspace.focusedColumn
            while col < workspace.columns.count - 1 {
                col += 1
                if !workspace.columns[col].windows.isEmpty {
                    workspace.focusedColumn = col
                    break
                }
            }
        case .up:
            let col = workspace.focusedColumn
            let count = workspace.columns[col].windows.count
            guard count > 0 else { return }
            let row = min(workspace.focusedWindowInColumn[col] ?? 0, count - 1)
            workspace.focusedWindowInColumn[col] = max(0, row - 1)
        case .down:
            let col = workspace.focusedColumn
            let count = workspace.columns[col].windows.count
            guard count > 0 else { return }
            let row = min(workspace.focusedWindowInColumn[col] ?? 0, count - 1)
            workspace.focusedWindowInColumn[col] = min(count - 1, row + 1)
        }
    }


    public func focus(_ direction: Direction, workspace: inout WorkspaceState, usable: Rect) {
        focus(direction, workspace: &workspace)
        snapViewToFocusedColumn(&workspace, usableWidth: usable.width)
    }


    public func moveFocused(_ direction: Direction, workspace: inout WorkspaceState, usable: Rect) {
        guard let focused = workspace.focusedWindowID else { return }
        guard let (col, row) = locate(focused, in: workspace) else { return }

        switch direction {
        case .left:
            if col == 0 {
                // Peel focused tile into a new left column (stack split).
                guard workspace.columns[col].windows.count > 1 else { return }
                workspace.columns[col].windows.remove(at: row)
                let width = defaultColumnWidth(
                    usable: usable,
                    columnCount: workspace.columns.count + 1
                )
                workspace.columns.insert(Column(windows: [focused], width: width), at: 0)
                shiftFocusMapAfterInsert(at: 0, workspace: &workspace)
                workspace.focusedColumn = 0
                workspace.focusedWindowInColumn[0] = 0
            } else {
                workspace.columns[col].windows.remove(at: row)
                workspace.columns[col - 1].windows.append(focused)
                workspace.focusedColumn = col - 1
                workspace.focusedWindowInColumn[col - 1] = workspace.columns[col - 1].windows.count - 1
                cleanupEmptyColumns(&workspace)
            }
        case .right:
            if col >= workspace.columns.count - 1 {
                // Peel focused tile into a new right column (stack split).
                guard workspace.columns[col].windows.count > 1 else { return }
                workspace.columns[col].windows.remove(at: row)
                let width = defaultColumnWidth(
                    usable: usable,
                    columnCount: workspace.columns.count + 1
                )
                let newIdx = workspace.columns.count
                workspace.columns.append(Column(windows: [focused], width: width))
                workspace.focusedColumn = newIdx
                workspace.focusedWindowInColumn[newIdx] = 0
            } else {
                workspace.columns[col].windows.remove(at: row)
                workspace.columns[col + 1].windows.append(focused)
                workspace.focusedColumn = col + 1
                workspace.focusedWindowInColumn[col + 1] = workspace.columns[col + 1].windows.count - 1
                cleanupEmptyColumns(&workspace)
            }
        case .up:
            guard row > 0 else { return }
            let above = workspace.columns[col].windows[row - 1]
            let below = workspace.columns[col].windows[row]
            workspace.columns[col].windows.swapAt(row, row - 1)
            workspace.focusedWindowInColumn[col] = row - 1
            swapLeafWeights(&workspace, above, below)
        case .down:
            guard row + 1 < workspace.columns[col].windows.count else { return }
            let above = workspace.columns[col].windows[row]
            let below = workspace.columns[col].windows[row + 1]
            workspace.columns[col].windows.swapAt(row, row + 1)
            workspace.focusedWindowInColumn[col] = row + 1
            swapLeafWeights(&workspace, above, below)
        }
        if columnsShouldFillUsable(count: workspace.columns.count) {
            ensureColumnWidths(workspace: &workspace, usable: usable)
            workspace.viewOffset = 0
        } else if needsColumnWidthRebalance(workspace: workspace, usable: usable) {
            ensureColumnWidths(workspace: &workspace, usable: usable)
        }
        snapViewToFocusedColumn(&workspace, usableWidth: usable.width)
    }
}
