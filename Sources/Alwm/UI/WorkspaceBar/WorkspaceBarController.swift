import AppKit
import Foundation
import AlwmPluginAPI

// MARK: - Workspace bar controller — state and render entry

@MainActor
public final class WorkspaceBarController {
    var windows: [CGDirectDisplayID: NSWindow] = [:]
    /// AppKit action target (not the @MainActor controller).
    let actionBridge = WorkspaceBarActionBridge()
    /// Skip full rebuild when the visible signature is unchanged.
    var lastRenderSignature = ""
    var pluginBarItems: [PluginBarItem] = []
    /// Menu-bar-style status text (workspace + focused window), shown at end of the pill when enabled.
    var focusedStatusLabel = ""

    /// Returns live ManagedWindows for a given bundleID/appName restricted to a workspace.
    /// Used by the multi-window picker to resolve token-churn cases.
    public var onWindowsForApp: ((String?, String, String) -> [ManagedWindow])?
    public var onSelectWorkspace: ((CGDirectDisplayID, String) -> Void)?
    /// Switch workspace if needed, then focus a tiled window (layout stays put).
    public var onFocusWorkspaceWindow: ((CGDirectDisplayID, String, WindowID) -> Void)?
    public var onMoveFocusedToWorkspace: ((String, Bool) -> Void)?
    public var onMoveWindowToWorkspace: ((WindowID, String, Bool) -> Void)?
    public var onCloseWindow: ((WindowID) -> Void)?
    public var onQuitApp: ((pid_t) -> Void)?
    public var onToggleFloatWindow: ((WindowID) -> Void)?
    public var onFocusFloatingOnMonitor: ((CGDirectDisplayID) -> Void)?
    /// Opens the ALWM status menu (same as the menu-bar icon).
    public var onFocusedStatusClicked: ((NSView) -> Void)?

    /// Snapshot of workspace chips for context menus (id + display name).
    var menuWorkspaces: [(id: String, name: String)] = []

    let accent = NSColor(hex: "#4FC3F7") ?? .systemTeal
    let separator = NSColor.white.withAlphaComponent(0.12)
    /// Avoid NSWorkspace.iconForFile on every chrome rebuild (main-thread freeze).
    var iconCache: [String: NSImage] = [:]
    /// Last render snapshots used to resolve multi-window app picks on icon click.
    var lastWorkspaces: [String: WorkspaceState] = [:]
    var lastWindowsByID: [WindowID: ManagedWindow] = [:]
    var lastWindowWorkspace: [WindowID: String] = [:]

    public init() {
        actionBridge.owner = self
    }

    public func render(
        monitors: [MonitorInfo],
        definitions: [WorkspaceDefinition],
        activeByMonitor: [CGDirectDisplayID: String],
        workspaces: [String: WorkspaceState],
        windowsByID: [WindowID: ManagedWindow],
        windowWorkspace: [WindowID: String] = [:],
        settings: WorkspaceBarSettings,
        mainHeight: Double,
        avoidRect: NSRect? = nil,
        pluginItems: [PluginBarItem] = [],
        focusedStatusLabel: String = ""
    ) {
        let signature = renderSignature(
            monitors: monitors,
            definitions: definitions,
            activeByMonitor: activeByMonitor,
            workspaces: workspaces,
            windowsByID: windowsByID,
            windowWorkspace: windowWorkspace,
            settings: settings,
            avoidRect: avoidRect,
            pluginItems: pluginItems,
            focusedStatusLabel: focusedStatusLabel
        )
        guard signature != lastRenderSignature else { return }
        lastRenderSignature = signature
        pluginBarItems = pluginItems
        self.focusedStatusLabel = focusedStatusLabel
        lastWorkspaces = workspaces
        lastWindowsByID = windowsByID
        lastWindowWorkspace = windowWorkspace

        guard settings.enabled else {
            hideAll()
            return
        }
        menuWorkspaces = definitions.map { ($0.id, $0.name.isEmpty ? $0.id : $0.name) }
        let ids = Set(monitors.map(\.id))
        for (id, win) in windows where !ids.contains(id) {
            win.orderOut(nil)
            windows.removeValue(forKey: id)
        }

        for mon in monitors {
            guard let screen = screen(for: mon.id) else { continue }
            let frame = screen.frame
            let visible = screen.visibleFrame
            let systemMenuHeight = max(22, frame.maxY - visible.maxY)
            let overlay = settings.position == .overlayMenuBar
            let activeID = activeByMonitor[mon.id]
            let monIdx = monitors.firstIndex(where: { $0.id == mon.id }) ?? 0
            let localDefs = WorkspaceStore.definitions(definitions, visibleOnMonitorIndex: monIdx)

            if overlay {
                renderOverlay(
                    monitor: mon,
                    monitors: monitors,
                    screenFrame: frame,
                    menuHeight: systemMenuHeight,
                    definitions: localDefs,
                    activeID: activeID,
                    workspaces: workspaces,
                    windowsByID: windowsByID,
                    windowWorkspace: windowWorkspace,
                    settings: settings,
                    avoidRect: avoidRect
                )
            } else {
                renderBelow(
                    monitor: mon,
                    monitors: monitors,
                    visible: visible,
                    definitions: localDefs,
                    activeID: activeID,
                    workspaces: workspaces,
                    windowsByID: windowsByID,
                    windowWorkspace: windowWorkspace,
                    settings: settings
                )
            }
        }
    }

    /// Compact window that only covers the workspace chips — never the system status items.


    public func hideAll() {
        lastRenderSignature = ""
        for (_, w) in windows { w.orderOut(nil) }
    }
}
