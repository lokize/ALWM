import Foundation

/// Pure layout engine: Niri-style scrolling columns. No AX / AppKit.
public struct ColumnLayoutEngine: Sendable {
    public var settings: LayoutSettings

    public init(settings: LayoutSettings = .default) {
        self.settings = settings
    }

    public func usableArea(monitor: Rect) -> Rect {
        Rect(
            x: monitor.x + settings.outerGap,
            y: monitor.y + settings.barHeight + settings.outerGap,
            width: max(0, monitor.width - settings.outerGap * 2),
            height: max(0, monitor.height - settings.barHeight - settings.outerGap * 2)
        )
    }

    public func defaultColumnWidth(usable: Rect) -> Double {
        defaultColumnWidth(usable: usable, columnCount: 1)
    }

    /// Width for a column when `columnCount` columns are meant to share the usable strip.
    /// Gaps are reserved inside usable so tiles never eat outer/inner margins.
    public func defaultColumnWidth(usable: Rect, columnCount: Int) -> Double {
        let n = max(1, columnCount)
        let ratio = settings.defaultColumnWidthRatio
        if columnsShouldFillUsable(count: n) {
            let budget = fillWidthBudget(columnCount: n, usable: usable)
            return max(settings.minColumnWidth, budget * ratio)
        }
        return max(settings.minColumnWidth, usable.width * ratio)
    }

    /// Total width available for column boxes (usable minus inner gaps between them).
    public func fillWidthBudget(columnCount: Int, usable: Rect) -> Double {
        let n = max(1, columnCount)
        let gaps = settings.gap * Double(max(0, n - 1))
        return max(Double(n) * settings.minColumnWidth, usable.width - gaps)
    }

    /// When N × default ratio fits in one screen, columns share usable (gap-aware).
    public func columnsShouldFillUsable(count: Int) -> Bool {
        let n = max(1, count)
        return Double(n) * settings.defaultColumnWidthRatio <= 1.0 + 1e-6
    }

    /// Column membership is authoritative — AX float subroles must not drop layout math.
    private func isLayoutEligible(_ win: ManagedWindow?) -> Bool {
        guard let win, !win.isIgnored, !win.isScratchpad else { return false }
        return true
    }

    private func columnHasLayoutTiles(
        _ column: Column,
        windows: [WindowID: ManagedWindow],
        layoutExcluded: Set<WindowID>
    ) -> Bool {
        column.windows.contains { wid in
            guard !layoutExcluded.contains(wid) else { return false }
            return isLayoutEligible(windows[wid])
        }
    }

    /// Columns that still own window ids — side-by-side slots survive while siblings are excluded.
    private func occupiedColumnCount(_ workspace: WorkspaceState) -> Int {
        workspace.columns.filter { !$0.windows.isEmpty }.count
    }

    private func snapHorizontalTileFrame(_ frame: Rect, usable: Rect) -> Rect {
        var f = frame
        if f.width > usable.width { f.width = usable.width }
        if f.x < usable.x { f.x = usable.x }
        if f.maxX > usable.maxX { f.x = max(usable.x, usable.maxX - f.width) }
        return f
    }

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

    private func swapLeafWeights(_ workspace: inout WorkspaceState, _ a: WindowID, _ b: WindowID) {
        let wa = workspace.leafWeights[a.token]
        let wb = workspace.leafWeights[b.token]
        guard wa != nil || wb != nil else { return }
        if let wa { workspace.leafWeights[b.token] = wa } else { workspace.leafWeights.removeValue(forKey: b.token) }
        if let wb { workspace.leafWeights[a.token] = wb } else { workspace.leafWeights.removeValue(forKey: a.token) }
    }

    /// Split `availableHeight` across stack windows by leafWeights (always fills the column).
    private static func stackHeights(
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

    /// After inserting a column, shift focus-map keys at/after the insert index (bounds-safe).
    private func shiftFocusMapAfterInsert(at insertIndex: Int, workspace: inout WorkspaceState) {
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

    private func cleanupEmptyColumns(_ workspace: inout WorkspaceState) {
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
