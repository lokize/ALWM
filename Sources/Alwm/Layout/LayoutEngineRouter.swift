import Foundation

/// Routes layout operations to Niri columns or Dwindle BSP per workspace.
public struct LayoutEngineRouter: Sendable {
    public var settings: LayoutSettings
    public var niri: ColumnLayoutEngine
    public var dwindle: DwindleLayoutEngine

    public init(settings: LayoutSettings = .default) {
        self.settings = settings
        self.niri = ColumnLayoutEngine(settings: settings)
        self.dwindle = DwindleLayoutEngine(settings: settings)
    }

    public mutating func applySettings(_ settings: LayoutSettings) {
        self.settings = settings
        niri.settings = settings
        dwindle.settings = settings
    }

    public func usableArea(monitor: Rect) -> Rect {
        niri.usableArea(monitor: monitor)
    }

    public func computeFrames(
        workspace: WorkspaceState,
        windows: [WindowID: ManagedWindow],
        monitor: Rect,
        active: Bool,
        stackExcluded: Set<WindowID> = [],
        layoutExcluded: Set<WindowID> = []
    ) -> [FrameAssignment] {
        switch workspace.layout {
        case .niri:
            return niri.computeFrames(
                workspace: workspace,
                windows: windows,
                monitor: monitor,
                active: active,
                stackExcluded: stackExcluded,
                layoutExcluded: layoutExcluded
            )
        case .dwindle:
            return dwindle.computeFrames(workspace: workspace, windows: windows, monitor: monitor, active: active)
        }
    }

    public func insertWindow(_ id: WindowID, into workspace: inout WorkspaceState, usable: Rect) {
        switch workspace.layout {
        case .niri:
            niri.insertWindow(id, into: &workspace, usable: usable)
        case .dwindle:
            dwindle.insertWindow(id, into: &workspace)
        }
    }

    public func insertWindowAsNewColumn(_ id: WindowID, into workspace: inout WorkspaceState, usable: Rect) {
        switch workspace.layout {
        case .niri:
            niri.insertWindowAsNewColumn(id, into: &workspace, usable: usable)
        case .dwindle:
            dwindle.insertWindow(id, into: &workspace)
        }
    }

    public func focus(
        _ direction: Direction,
        workspace: inout WorkspaceState,
        usable: Rect,
        windows: [WindowID: ManagedWindow],
        monitor: Rect
    ) {
        switch workspace.layout {
        case .niri:
            niri.focus(direction, workspace: &workspace, usable: usable)
        case .dwindle:
            dwindle.focus(direction, workspace: &workspace, windows: windows, monitor: monitor)
        }
    }

    public func moveFocused(
        _ direction: Direction,
        workspace: inout WorkspaceState,
        usable: Rect
    ) {
        switch workspace.layout {
        case .niri:
            niri.moveFocused(direction, workspace: &workspace, usable: usable)
        case .dwindle:
            dwindle.moveFocused(direction, workspace: &workspace)
        }
    }

    public func resizeFocused(by delta: Double, workspace: inout WorkspaceState, usable: Rect) {
        switch workspace.layout {
        case .niri:
            niri.resizeFocused(by: delta, workspace: &workspace, usable: usable)
        case .dwindle:
            dwindle.resizeFocused(by: delta, workspace: &workspace)
        }
    }

    public func resizeFocusedHeight(
        by delta: Double,
        workspace: inout WorkspaceState,
        usable: Rect,
        stackExcluded: Set<WindowID> = [],
        for focusedID: WindowID? = nil
    ) {
        switch workspace.layout {
        case .niri:
            niri.resizeFocusedHeight(
                by: delta,
                workspace: &workspace,
                usable: usable,
                stackExcluded: stackExcluded,
                for: focusedID
            )
        case .dwindle:
            dwindle.resizeFocused(by: delta, workspace: &workspace)
        }
    }

    public func toggleMaximizeFocusedColumn(workspace: inout WorkspaceState, usable: Rect) {
        switch workspace.layout {
        case .niri:
            niri.toggleMaximizeFocusedColumn(workspace: &workspace, usable: usable)
        case .dwindle:
            // Dwindle: grow focused leaf toward full usable weight.
            dwindle.resizeFocused(by: 400, workspace: &workspace)
        }
    }

    public func ensureColumnWidths(workspace: inout WorkspaceState, usable: Rect) {
        guard workspace.layout == .niri else { return }
        niri.ensureColumnWidths(workspace: &workspace, usable: usable)
    }

    public func fitAllColumnsOnScreen(workspace: inout WorkspaceState, usable: Rect, equalSplit: Bool = false) {
        guard workspace.layout == .niri else { return }
        niri.fitAllColumnsOnScreen(workspace: &workspace, usable: usable, equalSplit: equalSplit)
    }

    public func prepareLayoutForDisplay(
        workspace: inout WorkspaceState,
        usable: Rect,
        windows: [WindowID: ManagedWindow],
        layoutExcluded: Set<WindowID> = []
    ) {
        guard workspace.layout == .niri else { return }
        niri.prepareLayoutForDisplay(
            workspace: &workspace,
            usable: usable,
            windows: windows,
            layoutExcluded: layoutExcluded
        )
    }

    public func locate(_ id: WindowID, in workspace: WorkspaceState) -> (col: Int, row: Int)? {
        niri.locate(id, in: workspace)
    }

    public func scroll(by delta: Double, workspace: inout WorkspaceState, maxOffset: Double) {
        guard workspace.layout == .niri else { return }
        niri.scroll(by: delta, workspace: &workspace, maxOffset: maxOffset)
    }

    public func snapScroll(workspace: inout WorkspaceState, usable: Rect) {
        guard workspace.layout == .niri else { return }
        niri.snapScroll(workspace: &workspace, usable: usable)
    }

    public func maxViewOffset(workspace: WorkspaceState, usable: Rect) -> Double {
        guard workspace.layout == .niri else { return 0 }
        return niri.maxViewOffset(workspace: workspace, usable: usable)
    }

    public func snapViewToFocusedColumn(_ workspace: inout WorkspaceState, usable: Rect) {
        guard workspace.layout == .niri else { return }
        niri.snapViewToFocusedColumn(&workspace, usableWidth: usable.width)
    }
}
