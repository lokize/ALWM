import Foundation

/// Binary-space-partition layout (Hyprland/bspwm-style dwindle).
public struct DwindleLayoutEngine: Sendable {
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

    public func computeFrames(
        workspace: WorkspaceState,
        windows: [WindowID: ManagedWindow],
        monitor: Rect,
        active: Bool
    ) -> [FrameAssignment] {
        let usable = usableArea(monitor: monitor)
        // Park BELOW the monitor — left-park gets clamped into a visible strip by macOS.
        let parkX = monitor.midX - 40
        let parkY = monitor.maxY + max(monitor.height, 2500) + 1200
        let ids = workspace.orderedWindowIDs.filter { windows[$0]?.isTiled == true }

        if !active {
            return ids.map { wid in
                let w = windows[wid]!
                return FrameAssignment(
                    windowID: wid,
                    frame: Rect(
                        x: parkX,
                        y: parkY,
                        width: max(w.minSize.width, usable.width / 2),
                        height: max(w.minSize.height, usable.height / 2)
                    ),
                    visible: false
                )
            }
        }

        guard !ids.isEmpty else { return [] }
        var result: [FrameAssignment] = []
        split(ids: ids, area: usable, depth: 0, workspace: workspace, into: &result)
        return result
    }

    private func weight(_ id: WindowID, workspace: WorkspaceState) -> Double {
        max(0.15, workspace.leafWeights[id.token] ?? 1)
    }

    private func split(
        ids: [WindowID],
        area: Rect,
        depth: Int,
        workspace: WorkspaceState,
        into result: inout [FrameAssignment]
    ) {
        guard let first = ids.first else { return }
        if ids.count == 1 {
            result.append(FrameAssignment(windowID: first, frame: area, visible: true))
            return
        }

        let mid = max(1, ids.count / 2)
        let leftIDs = Array(ids[..<mid])
        let rightIDs = Array(ids[mid...])
        let gap = settings.gap
        let leftWeight = leftIDs.reduce(0.0) { $0 + weight($1, workspace: workspace) }
        let rightWeight = rightIDs.reduce(0.0) { $0 + weight($1, workspace: workspace) }
        let total = max(0.01, leftWeight + rightWeight)
        let splitVertical = depth % 2 == 0

        if splitVertical {
            let avail = max(0, area.width - gap)
            let leftW = avail * (leftWeight / total)
            let rightW = avail - leftW
            let leftArea = Rect(x: area.x, y: area.y, width: leftW, height: area.height)
            let rightArea = Rect(x: area.x + leftW + gap, y: area.y, width: rightW, height: area.height)
            split(ids: leftIDs, area: leftArea, depth: depth + 1, workspace: workspace, into: &result)
            split(ids: rightIDs, area: rightArea, depth: depth + 1, workspace: workspace, into: &result)
        } else {
            let avail = max(0, area.height - gap)
            let topH = avail * (leftWeight / total)
            let botH = avail - topH
            let topArea = Rect(x: area.x, y: area.y, width: area.width, height: topH)
            let botArea = Rect(x: area.x, y: area.y + topH + gap, width: area.width, height: botH)
            split(ids: leftIDs, area: topArea, depth: depth + 1, workspace: workspace, into: &result)
            split(ids: rightIDs, area: botArea, depth: depth + 1, workspace: workspace, into: &result)
        }
    }

    /// Focus neighbor by geometric adjacency of dwindle frames.
    public func focus(
        _ direction: Direction,
        workspace: inout WorkspaceState,
        windows: [WindowID: ManagedWindow],
        monitor: Rect
    ) {
        guard let current = workspace.focusedWindowID else { return }
        let frames = Dictionary(
            uniqueKeysWithValues: computeFrames(
                workspace: workspace,
                windows: windows,
                monitor: monitor,
                active: true
            ).map { ($0.windowID, $0.frame) }
        )
        guard let cur = frames[current] else { return }

        var best: (WindowID, Double)?
        for (id, frame) in frames where id != current {
            let score: Double?
            switch direction {
            case .left:
                guard frame.maxX <= cur.x + 1 else { continue }
                let overlap = verticalOverlap(cur, frame)
                guard overlap > 0 else { continue }
                score = cur.x - frame.maxX
            case .right:
                guard frame.x >= cur.maxX - 1 else { continue }
                let overlap = verticalOverlap(cur, frame)
                guard overlap > 0 else { continue }
                score = frame.x - cur.maxX
            case .up:
                guard frame.maxY <= cur.y + 1 else { continue }
                let overlap = horizontalOverlap(cur, frame)
                guard overlap > 0 else { continue }
                score = cur.y - frame.maxY
            case .down:
                guard frame.y >= cur.maxY - 1 else { continue }
                let overlap = horizontalOverlap(cur, frame)
                guard overlap > 0 else { continue }
                score = frame.y - cur.maxY
            }
            if let score, best == nil || score < best!.1 {
                best = (id, score)
            }
        }
        if let id = best?.0 {
            select(id, in: &workspace)
        }
    }

    public func moveFocused(
        _ direction: Direction,
        workspace: inout WorkspaceState
    ) {
        guard let focused = workspace.focusedWindowID else { return }
        var order = workspace.orderedWindowIDs
        guard let idx = order.firstIndex(of: focused) else { return }
        let target: Int
        switch direction {
        case .left, .up: target = max(0, idx - 1)
        case .right, .down: target = min(order.count - 1, idx + 1)
        }
        guard target != idx else { return }
        order.swapAt(idx, target)
        rebuildColumns(from: order, focused: focused, workspace: &workspace)
    }

    public func resizeFocused(by delta: Double, workspace: inout WorkspaceState) {
        guard let focused = workspace.focusedWindowID else { return }
        let key = focused.token
        let current = workspace.leafWeights[key] ?? 1
        workspace.leafWeights[key] = max(0.15, current + delta / 120)
    }

    public func insertWindow(_ id: WindowID, into workspace: inout WorkspaceState) {
        if workspace.orderedWindowIDs.contains(id) { return }
        var order = workspace.orderedWindowIDs
        if let focused = workspace.focusedWindowID, let idx = order.firstIndex(of: focused) {
            order.insert(id, at: idx + 1)
        } else {
            order.append(id)
        }
        if workspace.leafWeights[id.token] == nil {
            workspace.leafWeights[id.token] = 1
        }
        rebuildColumns(from: order, focused: id, workspace: &workspace)
    }

    public func select(_ id: WindowID, in workspace: inout WorkspaceState) {
        for (c, col) in workspace.columns.enumerated() {
            if let r = col.windows.firstIndex(of: id) {
                workspace.focusedColumn = c
                workspace.focusedWindowInColumn[c] = r
                return
            }
        }
    }

    private func rebuildColumns(from order: [WindowID], focused: WindowID, workspace: inout WorkspaceState) {
        workspace.columns = order.map { Column(windows: [$0], width: 0) }
        select(focused, in: &workspace)
    }

    private func verticalOverlap(_ a: Rect, _ b: Rect) -> Double {
        max(0, min(a.maxY, b.maxY) - max(a.y, b.y))
    }

    private func horizontalOverlap(_ a: Rect, _ b: Rect) -> Double {
        max(0, min(a.maxX, b.maxX) - max(a.x, b.x))
    }
}
