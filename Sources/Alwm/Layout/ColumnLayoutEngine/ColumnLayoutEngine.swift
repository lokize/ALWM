import Foundation

/// Pure layout engine: Niri-style scrolling columns. No AX / AppKit.

// MARK: - Column layout engine — settings and geometry

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
    func isLayoutEligible(_ win: ManagedWindow?) -> Bool {
        guard let win, !win.isIgnored, !win.isScratchpad else { return false }
        return true
    }

    func columnHasLayoutTiles(
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
    func occupiedColumnCount(_ workspace: WorkspaceState) -> Int {
        workspace.columns.filter { !$0.windows.isEmpty }.count
    }

    func snapHorizontalTileFrame(_ frame: Rect, usable: Rect) -> Rect {
        var f = frame
        if f.width > usable.width { f.width = usable.width }
        if f.x < usable.x { f.x = usable.x }
        if f.maxX > usable.maxX { f.x = max(usable.x, usable.maxX - f.width) }
        return f
    }
}

