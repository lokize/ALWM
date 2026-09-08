import Foundation

/// Pure layout engine: Niri-style scrolling columns. No AX / AppKit.

// MARK: - Column layout — scroll and resize

extension ColumnLayoutEngine {

    public func scroll(by delta: Double, workspace: inout WorkspaceState, maxOffset: Double) {
        workspace.viewOffset = min(max(0, workspace.viewOffset + delta), max(0, maxOffset))
    }


    public func snapScroll(workspace: inout WorkspaceState, usable: Rect) {
        guard settings.gestures.scrollSnap, !workspace.columns.isEmpty else { return }
        let n = workspace.columns.count
        let defaultW = defaultColumnWidth(usable: usable, columnCount: n)
        var x: Double = 0
        var best = 0
        var bestDist = Double.greatestFiniteMagnitude
        for (i, column) in workspace.columns.enumerated() {
            let w = column.width > 0 ? column.width : defaultW
            let dist = abs(x - workspace.viewOffset)
            if dist < bestDist {
                bestDist = dist
                best = i
            }
            x += w + settings.gap
        }
        var target: Double = 0
        for i in 0..<best {
            let w = workspace.columns[i].width > 0 ? workspace.columns[i].width : defaultW
            target += w + settings.gap
        }
        workspace.viewOffset = min(target, maxViewOffset(workspace: workspace, usable: usable))
        workspace.focusedColumn = best
    }


    public func contentWidth(workspace: WorkspaceState, usable: Rect) -> Double {
        guard !workspace.columns.isEmpty else { return 0 }
        let n = workspace.columns.count
        let defaultW = defaultColumnWidth(usable: usable, columnCount: n)
        let widths = workspace.columns.map { $0.width > 0 ? $0.width : defaultW }
        let gaps = settings.gap * Double(max(0, widths.count - 1))
        return widths.reduce(0, +) + gaps
    }


    public func maxViewOffset(workspace: WorkspaceState, usable: Rect) -> Double {
        max(0, contentWidth(workspace: workspace, usable: usable) - usable.width)
    }


    public func snapViewToFocusedColumn(_ workspace: inout WorkspaceState, usableWidth: Double) {
        guard usableWidth > 0, !workspace.columns.isEmpty else { return }
        let col = min(max(0, workspace.focusedColumn), workspace.columns.count - 1)
        let n = workspace.columns.count
        let usable = Rect(x: 0, y: 0, width: usableWidth, height: 1)
        let defaultW = defaultColumnWidth(usable: usable, columnCount: n)
        var x: Double = 0
        for i in 0..<col {
            let w = workspace.columns[i].width > 0 ? workspace.columns[i].width : defaultW
            x += w + settings.gap
        }
        let colW = workspace.columns[col].width > 0 ? workspace.columns[col].width : defaultW
        if x < workspace.viewOffset {
            workspace.viewOffset = x
        } else if x + colW > workspace.viewOffset + usableWidth {
            workspace.viewOffset = max(0, x + colW - usableWidth)
        }
    }


    /// Grow/shrink the focused window's height inside its column; balance from neighbor above/below.
    /// Operates on visible stack siblings only and always keeps the column fully filled.
    public func resizeFocusedHeight(
        by delta: Double,
        workspace: inout WorkspaceState,
        usable: Rect,
        stackExcluded: Set<WindowID> = [],
        for focusedID: WindowID? = nil
    ) {
        guard let focused = focusedID ?? workspace.focusedWindowID,
              locate(focused, in: workspace) != nil else { return }
        let col = locate(focused, in: workspace)!.col
        guard workspace.columns.indices.contains(col) else { return }
        let rawIDs = workspace.columns[col].windows
        let stackIDs = {
            let eligible = rawIDs.filter { !stackExcluded.contains($0) }
            return eligible.isEmpty ? rawIDs : eligible
        }()
        guard stackIDs.count >= 2,
              let row = stackIDs.firstIndex(of: focused)
        else { return }

        // Leaving maximize so height weights take effect again.
        workspace.columns[col].isMaximized = false

        for id in stackIDs where workspace.leafWeights[id.token] == nil {
            workspace.leafWeights[id.token] = 1.0 / Double(stackIDs.count)
        }

        let gaps = settings.gap * Double(max(0, stackIDs.count - 1))
        let availableHeight = max(1, usable.height - gaps)
        let minH = max(48, availableHeight * 0.12)

        var heights: [Double] = stackIDs.map { id in
            let w = max(0.15, workspace.leafWeights[id.token] ?? 1)
            return w
        }
        let sumW = max(0.15, heights.reduce(0, +))
        heights = heights.map { availableHeight * ($0 / sumW) }

        let neighbor: Int? = {
            if delta >= 0 {
                if row - 1 >= 0 { return row - 1 }
                if row + 1 < stackIDs.count { return row + 1 }
            } else {
                if row + 1 < stackIDs.count { return row + 1 }
                if row - 1 >= 0 { return row - 1 }
            }
            return nil
        }()
        guard let neighbor else { return }

        let newH = min(max(minH, heights[row] + delta), availableHeight - minH)
        let applied = newH - heights[row]
        heights[row] = newH
        heights[neighbor] = max(minH, heights[neighbor] - applied)

        // Absorb float drift so the stack still fills the column.
        let total = heights.reduce(0, +)
        if let last = heights.indices.last {
            heights[last] = max(minH, heights[last] + (availableHeight - total))
        }

        for (i, id) in stackIDs.enumerated() {
            // Normalized slot weights — computeFrames scales back to pixels.
            workspace.leafWeights[id.token] = max(0.15, heights[i] / availableHeight)
        }
    }


    func swapLeafWeights(_ workspace: inout WorkspaceState, _ a: WindowID, _ b: WindowID) {
        let wa = workspace.leafWeights[a.token]
        let wb = workspace.leafWeights[b.token]
        guard wa != nil || wb != nil else { return }
        if let wa { workspace.leafWeights[b.token] = wa } else { workspace.leafWeights.removeValue(forKey: b.token) }
        if let wb { workspace.leafWeights[a.token] = wb } else { workspace.leafWeights.removeValue(forKey: a.token) }
    }


    /// Grow/shrink the focused column; balance is taken from the neighbor.
    /// When columns are meant to share one screen, widths stay inside usable minus gaps.
    public func resizeFocused(by delta: Double, workspace: inout WorkspaceState, usable: Rect) {
        guard !workspace.columns.isEmpty else { return }
        ensureColumnWidths(workspace: &workspace, usable: usable)
        let col = min(max(0, workspace.focusedColumn), workspace.columns.count - 1)
        let minW = settings.minColumnWidth
        let n = workspace.columns.count
        let fill = columnsShouldFillUsable(count: n)
            || contentWidth(workspace: workspace, usable: usable) <= usable.width + 1.0

        if fill, n >= 2 {
            normalizeWidthsToFill(workspace: &workspace, usable: usable)
            let neighbor: Int? = {
                if delta >= 0, col + 1 < n { return col + 1 }
                if delta < 0, col - 1 >= 0 { return col - 1 }
                if col + 1 < n { return col + 1 }
                if col - 1 >= 0 { return col - 1 }
                return nil
            }()
            guard let neighbor else {
                snapViewToFocusedColumn(&workspace, usableWidth: usable.width)
                return
            }
            let pairBudget = workspace.columns[col].width + workspace.columns[neighbor].width
            let next = min(
                max(minW, workspace.columns[col].width + delta),
                max(minW, pairBudget - minW)
            )
            workspace.columns[col].width = next
            workspace.columns[neighbor].width = max(minW, pairBudget - next)
            workspace.viewOffset = 0
            snapViewToFocusedColumn(&workspace, usableWidth: usable.width)
            return
        }

        let neighbor = delta >= 0 ? col + 1 : col - 1
        let next = max(minW, workspace.columns[col].width + delta)
        let applied = next - workspace.columns[col].width
        workspace.columns[col].width = next
        if workspace.columns.indices.contains(neighbor) {
            workspace.columns[neighbor].width = max(
                minW,
                workspace.columns[neighbor].width - applied
            )
        }
        snapViewToFocusedColumn(&workspace, usableWidth: usable.width)
    }


    /// Toggle fill: focused window expands to the full column
    /// (siblings parked), occupying empty space above/below without stealing other columns.
    public func toggleMaximizeFocusedColumn(workspace: inout WorkspaceState, usable: Rect) {
        guard !workspace.columns.isEmpty else { return }
        ensureColumnWidths(workspace: &workspace, usable: usable)
        let col = min(max(0, workspace.focusedColumn), workspace.columns.count - 1)

        if workspace.columns[col].isMaximized {
            workspace.columns[col].isMaximized = false
            snapViewToFocusedColumn(&workspace, usableWidth: usable.width)
            return
        }

        // Only one filled column at a time.
        for i in workspace.columns.indices where i != col {
            workspace.columns[i].isMaximized = false
        }
        workspace.columns[col].isMaximized = true
        snapViewToFocusedColumn(&workspace, usableWidth: usable.width)
    }


    public func locate(_ id: WindowID, in workspace: WorkspaceState) -> (col: Int, row: Int)? {
        for (c, column) in workspace.columns.enumerated() {
            if let r = column.windows.firstIndex(of: id) {
                return (c, r)
            }
        }
        return nil
    }
}
