import Foundation

/// Pure layout engine: Niri-style scrolling columns. No AX / AppKit.

// MARK: - Column layout — compute frames and widths

extension ColumnLayoutEngine {

    public func computeFrames(
        workspace: WorkspaceState,
        windows: [WindowID: ManagedWindow],
        monitor: Rect,
        active: Bool,
        stackExcluded: Set<WindowID> = [],
        layoutExcluded: Set<WindowID> = []
    ) -> [FrameAssignment] {
        let usable = usableArea(monitor: monitor)
        var assignments: [FrameAssignment] = []
        // Park BELOW the monitor — left-park gets clamped into a visible strip by macOS.
        let parkX = monitor.midX - 40
        let parkY = monitor.maxY + max(monitor.height, 2500) + 1200

        let columnsWithTiles = workspace.columns.filter {
            columnHasLayoutTiles($0, windows: windows, layoutExcluded: layoutExcluded)
        }
        let layoutColumnCount = max(1, columnsWithTiles.count)
        let defaultW = defaultColumnWidth(usable: usable, columnCount: layoutColumnCount)

        if !active {
            for column in workspace.columns {
                for wid in column.windows {
                    guard let win = windows[wid], isLayoutEligible(win) else { continue }
                    let parked = Rect(
                        x: parkX,
                        y: parkY,
                        width: max(win.minSize.width, column.width > 0 ? column.width : defaultW),
                        height: max(win.minSize.height, usable.height)
                    )
                    assignments.append(FrameAssignment(windowID: wid, frame: parked, visible: false))
                }
            }
            return assignments
        }

        var cursorX = usable.x - workspace.viewOffset
        let soleEligibleColumn = columnsWithTiles.count <= 1

        for (colIndex, column) in workspace.columns.enumerated() {
            let hasTiles = columnHasLayoutTiles(column, windows: windows, layoutExcluded: layoutExcluded)
            if !hasTiles {
                continue
            }
            let colStartX = cursorX
            let colWidth: Double = {
                let saved = column.width > 0 ? column.width : defaultW
                guard hasTiles else { return saved }
                // Only expand when no other layout-eligible column remains.
                // Soft-missing siblings on the active WS stay eligible (see layoutExcluded),
                // so switch-back keeps WhatsApp/Discord column widths.
                if soleEligibleColumn {
                    return usable.width
                }
                return saved
            }()
            let columnStart = assignments.count
            let tiledAll = column.windows.compactMap { wid -> (WindowID, ManagedWindow)? in
                guard !layoutExcluded.contains(wid) else { return nil }
                guard let win = windows[wid], isLayoutEligible(win) else { return nil }
                return (wid, win)
            }

            let focusedRow = workspace.focusedWindowInColumn[colIndex] ?? 0
            // Minimized / hidden siblings stay in the column list but must not steal vertical space.
            let stackEligible: [(WindowID, ManagedWindow)] = {
                let eligible = tiledAll.filter { !stackExcluded.contains($0.0) }
                if !eligible.isEmpty { return eligible }
                // All excluded (e.g. soft-missing) — keep one stand-in so the column isn't empty.
                guard !tiledAll.isEmpty else { return [] }
                let row = min(focusedRow, tiledAll.count - 1)
                return [tiledAll[row]]
            }()
            let stackEligibleIDs = Set(stackEligible.map(\.0))
            // Never also park a window that was promoted into stackEligible (duplicate
            // FrameAssignment → Dictionary crash on apply).
            let parkedFromStack = tiledAll.filter {
                stackExcluded.contains($0.0) && !stackEligibleIDs.contains($0.0)
            }

            let gaps = settings.gap * Double(max(0, stackEligible.count - 1))
            let availableHeight = max(0, usable.height - gaps)
            let equalHeight = availableHeight / Double(max(1, stackEligible.count))
            // Only tab when a window cannot fit its *reserved* slot (gap already excluded).
            let needsTabbing = stackEligible.contains { $0.1.minSize.height > equalHeight + 0.5 }
            // After the user resizes heights, keep weighted stack — don't flip back to tabbing
            // (that parked siblings and left the focused tile looking "out of layout").
            let hasCustomHeights = stackEligible.contains { pair in
                workspace.leafWeights[pair.0.token] != nil
            }
            // Multi-window columns always share the stack — tabbing parks siblings off-screen
            // and leaves tiles looking like they ignored the column layout.
            let fillColumn = column.isMaximized
                || (stackEligible.count < 2 && needsTabbing && !hasCustomHeights)
            // Map column focus (full list) onto the eligible stack — row indices diverge
            // when minimized siblings are excluded.
            let focusedID: WindowID? = {
                if tiledAll.indices.contains(focusedRow) { return tiledAll[focusedRow].0 }
                return workspace.focusedWindowID
            }()
            let stackFocusedRow: Int = {
                if let focusedID,
                   let idx = stackEligible.firstIndex(where: { $0.0 == focusedID }) {
                    return idx
                }
                return min(focusedRow, max(0, stackEligible.count - 1))
            }()

            if fillColumn {
                for (row, pair) in stackEligible.enumerated() {
                    let (wid, _) = pair
                    if row == stackFocusedRow {
                        var frame = Rect(x: cursorX, y: usable.y, width: colWidth, height: usable.height)
                        frame = snapHorizontalTileFrame(frame, usable: usable)
                        assignments.append(FrameAssignment(windowID: wid, frame: frame, visible: true))
                    } else {
                        // Off-screen but still "visible" to the WM — never minimize tabbed
                        // siblings.
                        let parked = Rect(x: parkX, y: parkY, width: colWidth, height: usable.height)
                        assignments.append(FrameAssignment(windowID: wid, frame: parked, visible: true))
                    }
                }
            } else {
                // Weighted partition — tiles share the full column height (gaps only between rows).
                let heights = Self.stackHeights(
                    stackEligible: stackEligible,
                    leafWeights: workspace.leafWeights,
                    availableHeight: availableHeight
                )
                var y = usable.y
                for (index, pair) in stackEligible.enumerated() {
                    let (wid, _) = pair
                    let isLast = index == stackEligible.count - 1
                    let h = isLast ? max(0, usable.maxY - y) : heights[index]
                    var frame = Rect(x: cursorX, y: y, width: colWidth, height: h)
                    frame = snapHorizontalTileFrame(frame, usable: usable)
                    if isLast {
                        frame.height = max(0, usable.maxY - frame.y)
                    }
                    assignments.append(FrameAssignment(windowID: wid, frame: frame, visible: true))
                    y = frame.maxY + settings.gap
                }
            }

            for (wid, _) in parkedFromStack {
                // Soft-missing / user-minimized: keep slot but park without hide thrash.
                let parked = Rect(x: parkX, y: parkY, width: colWidth, height: usable.height)
                assignments.append(FrameAssignment(windowID: wid, frame: parked, visible: true))
            }

            let reservesHorizontalSlot = assignments[columnStart...].contains { assignment in
                assignment.visible
                    && abs(assignment.frame.x - colStartX) < 1.5
                    && assignment.frame.width > 48
            }
            if reservesHorizontalSlot {
                cursorX += colWidth + settings.gap
            } else {
                for index in columnStart..<assignments.count {
                    var parked = assignments[index]
                    guard parked.visible, abs(parked.frame.x - colStartX) < 1.5 else { continue }
                    parked.frame = Rect(x: parkX, y: parkY, width: colWidth, height: usable.height)
                    parked.visible = false
                    assignments[index] = parked
                }
            }
        }

        return assignments
    }


    public func ensureColumnWidths(workspace: inout WorkspaceState, usable: Rect) {
        let n = max(1, workspace.columns.count)
        let defaultW = defaultColumnWidth(usable: usable, columnCount: n)
        for i in workspace.columns.indices where workspace.columns[i].width <= 0 {
            workspace.columns[i].width = defaultW
        }
        if columnsShouldFillUsable(count: n),
           needsColumnWidthRebalance(workspace: workspace, usable: usable) {
            normalizeWidthsToFill(workspace: &workspace, usable: usable)
        }
    }


    /// Rebalance columns + view scroll before showing a workspace (fixes gaps after switch-back).
    public func prepareLayoutForDisplay(
        workspace: inout WorkspaceState,
        usable: Rect,
        windows: [WindowID: ManagedWindow],
        layoutExcluded: Set<WindowID> = []
    ) {
        pruneEmptyTileColumns(workspace: &workspace, windows: windows, layoutExcluded: layoutExcluded)
        guard !workspace.columns.isEmpty else {
            workspace.viewOffset = 0
            return
        }
        workspace.viewOffset = 0
        let n = workspace.columns.count
        let occupied = occupiedColumnCount(workspace)
        let layoutN = max(n, max(1, occupied))
        let defaultW = defaultColumnWidth(usable: usable, columnCount: layoutN)
        for i in workspace.columns.indices where workspace.columns[i].width <= 0 {
            workspace.columns[i].width = defaultW
        }
        if occupied <= 1, n == 1 {
            let budget = fillWidthBudget(columnCount: 1, usable: usable)
            workspace.columns[0].width = max(settings.minColumnWidth, budget)
            workspace.viewOffset = 0
            return
        }
        // Rebalance only when totals drifted — preserve user-tuned ratios on workspace switch-back.
        let width = contentWidth(workspace: workspace, usable: usable)
        if width <= usable.width + 1.0 {
            if needsColumnWidthRebalance(workspace: workspace, usable: usable) {
                normalizeWidthsToFill(workspace: &workspace, usable: usable)
            }
            workspace.viewOffset = 0
            return
        }
        if columnsShouldFillUsable(count: n),
           needsColumnWidthRebalance(workspace: workspace, usable: usable) {
            normalizeWidthsToFill(workspace: &workspace, usable: usable)
        }
        snapViewToFocusedColumn(&workspace, usableWidth: usable.width)
        if contentWidth(workspace: workspace, usable: usable) <= usable.width + 1.0 {
            workspace.viewOffset = 0
        }
    }


    /// Drop vacant placeholders and ghost columns (all layout-excluded) when enough
    /// eligible columns remain. Side-by-side slots survive while a sibling is minimized.
    public func pruneEmptyTileColumns(
        workspace: inout WorkspaceState,
        windows: [WindowID: ManagedWindow],
        layoutExcluded: Set<WindowID> = []
    ) {
        let focused = workspace.focusedWindowID
        let eligibleColumns = workspace.columns.filter {
            columnHasLayoutTiles($0, windows: windows, layoutExcluded: layoutExcluded)
        }.count
        workspace.columns.removeAll { col in
            if col.windows.isEmpty { return true }
            guard eligibleColumns >= 2 else { return false }
            return !columnHasLayoutTiles(col, windows: windows, layoutExcluded: layoutExcluded)
        }
        guard !workspace.columns.isEmpty else { return }
        if let focused, let loc = locate(focused, in: workspace) {
            workspace.focusedColumn = loc.col
        }
        workspace.focusedColumn = min(max(0, workspace.focusedColumn), workspace.columns.count - 1)
    }


    /// Scale column widths so sum(widths) + gaps == usable.width (preserves proportions).
    public func normalizeWidthsToFill(workspace: inout WorkspaceState, usable: Rect) {
        let n = workspace.columns.count
        guard n >= 1 else { return }
        let budget = fillWidthBudget(columnCount: n, usable: usable)
        let minW = settings.minColumnWidth
        let defaultW = budget / Double(n)
        var widths = workspace.columns.map { $0.width > 0 ? $0.width : defaultW }
        var sum = widths.reduce(0, +)
        if sum <= 0 {
            let equal = budget / Double(n)
            for i in workspace.columns.indices {
                workspace.columns[i].width = max(minW, equal)
            }
            return
        }
        if abs(sum - budget) <= 0.5 {
            for i in workspace.columns.indices {
                workspace.columns[i].width = max(minW, widths[i])
            }
            sum = workspace.columns.reduce(0.0) { $0 + $1.width }
            if abs(sum - budget) <= 0.5 { return }
            widths = workspace.columns.map(\.width)
            sum = widths.reduce(0, +)
        }
        let scale = budget / sum
        for i in workspace.columns.indices {
            workspace.columns[i].width = max(minW, widths[i] * scale)
        }
        // Absorb float drift on the last column.
        sum = workspace.columns.reduce(0.0) { $0 + $1.width }
        if let last = workspace.columns.indices.last {
            workspace.columns[last].width = max(minW, workspace.columns[last].width + (budget - sum))
        }
    }


    /// True when column widths must be rebalanced (overflow or uninitialized slots).
    /// Does not scale up when sum < budget — that preserved user ratios after ghost-column prune.
    public func needsColumnWidthRebalance(workspace: WorkspaceState, usable: Rect) -> Bool {
        let n = workspace.columns.count
        guard n >= 1 else { return false }
        let budget = fillWidthBudget(columnCount: n, usable: usable)
        var sum = 0.0
        for col in workspace.columns {
            if col.width <= 0 { return true }
            sum += col.width
        }
        return sum > budget + 1.0
    }


    /// Split `availableHeight` across stack windows by leafWeights (always fills the column).
    static func stackHeights(
        stackEligible: [(WindowID, ManagedWindow)],
        leafWeights: [String: Double],
        availableHeight: Double
    ) -> [Double] {
        let n = stackEligible.count
        guard n >= 1, availableHeight > 0 else {
            return Array(repeating: 0, count: max(0, n))
        }
        let weights = stackEligible.map { max(0.15, leafWeights[$0.0.token] ?? 1.0) }
        let sumW = max(0.15, weights.reduce(0, +))
        var heights = weights.map { availableHeight * ($0 / sumW) }
        let total = heights.reduce(0, +)
        if let last = heights.indices.last, abs(total - availableHeight) > 0.5 {
            heights[last] = max(48, heights[last] + (availableHeight - total))
        }
        return heights
    }
}
