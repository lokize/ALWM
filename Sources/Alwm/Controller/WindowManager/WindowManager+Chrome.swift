import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC
import AlwmPluginAPI

// MARK: - Chrome — border, workspace bar, diagnostics dump

extension WindowManager {
    func refreshBorder() {
        guard configStore.config.settings.borders.enabled else {
            border.hide()
            return
        }
        // Plugin / status / menu-bar / settings / quake / notepad chrome sits over tiles —
        // keep the focus ring hidden so it doesn't cut through overlays.
        if overlaysCaptureFocus
            || settingsUI.isVisible
            || PluginPanelOutsideClick.hasVisiblePanel
            || statusPopover.isShown
            || AlwmChromeFocus.menuBarMenuIsOpen() {
            border.hide()
            return
        }
        let mainHeight = Double(NSScreen.screens.first?.frame.height ?? 900)
        guard let mon = primaryMonitor() else {
            border.hide()
            return
        }

        // Prefer AX focus when it is a float/dialog or belongs to the active workspace.
        let focused: WindowID? = {
            if let axID = axFocusedWindowID ?? ax.frontmostFocusedWindowID(),
               let win = windowsByID[axID],
               !win.isIgnored {
                if win.isFloating || win.isScratchpad { return axID }
                if windowIsOnActiveWorkspace(axID, monitor: mon) { return axID }
            }
            return workspaces.activeWorkspace(for: mon.id)?.focusedWindowID
        }()

        guard let focused else {
            border.hide()
            return
        }
        // Quake scratchpad: no focus ring (drops from the edge like a HUD).
        if focused == quake.windowID {
            border.hide()
            return
        }
        // App transient popups (sticker pickers, etc.): don't ring the popup itself —
        // ring the owning main window when possible.
        let borderTarget: WindowID = {
            guard let win = windowsByID[focused],
                  win.isFloating || floatingOverrides.contains(focused),
                  !win.isScratchpad
            else { return focused }
            let usable = usableAreaNear(lastFrames[focused] ?? win.frame)
            guard !looksLikeMainTiledWindow(lastFrames[focused] ?? win.frame, usable: usable) else {
                return focused
            }
            // Prefer a tiled sibling of the same app on the active workspace.
            if let main = windowsByID.keys.first(where: { id in
                guard id.pid == focused.pid, id != focused else { return false }
                guard let candidate = windowsByID[id], !candidate.isIgnored else { return false }
                if candidate.isFloating || floatingOverrides.contains(id) { return false }
                return windowIsOnActiveWorkspace(id, monitor: mon)
            }) {
                return main
            }
            return focused
        }()

        // Always hug the live AX chrome — tile targets often oversize apps that refuse the
        // exact frame (Electron/WhatsApp), which left the stroke floating outside the window.
        let frame = ax.currentFrame(of: borderTarget) ?? windowsByID[borderTarget]?.frame
        let monitors = monitors.monitors.map(\.frame)
        guard let frame,
              OffscreenParking.isUsableOnscreenFrame(frame, monitors: monitors)
        else {
            border.hide()
            return
        }
        border.show(
            around: frame,
            windowNumber: borderTarget.windowNumber,
            monitors: monitors,
            monitorMainHeight: mainHeight
        )
    }

    func refreshChromeNow() {
        let mainHeight = Double(NSScreen.screens.first?.frame.height ?? 900)
        let barSettings = configStore.config.settings.workspaceBar
        refreshStatusItem()
        if barSettings.enabled {
            // Soft-missing / AX churn ghosts must never keep workspace icons (Safari on WS2
            // while only Cursor is tiled). Floats still reach the ⌀ chip via the same filter.
            let barWindows = windowsByID.filter { id, _ in
                missingScanCounts[id] == nil
            }
            bar.render(
                monitors: monitors.monitors,
                definitions: configStore.config.workspaces,
                activeByMonitor: workspaces.activeWorkspaceByMonitor,
                workspaces: workspaces.workspaces,
                windowsByID: barWindows,
                windowWorkspace: windowWorkspace,
                settings: barSettings,
                mainHeight: mainHeight,
                avoidRect: statusItemScreenFrame(),
                pluginItems: PluginManager.shared.barItemsSnapshot(),
                focusedStatusLabel: barSettings.showFocusedStatus ? statusBarWindowLabel() : ""
            )
        } else {
            bar.hideAll()
        }
        refreshBorder()
    }

    public func dumpRuntimeState() {
        guard configStore.config.settings.developerMode else {
            NSLog("ALWM: enable developerMode to dump runtime state")
            return
        }
        var lines: [String] = []
        lines.append("ALWM runtime dump")
        lines.append("monitors=\(monitors.monitors.count)")
        lines.append("windows=\(windowsByID.count)")
        lines.append("quake=\(quake.windowID?.token ?? "nil") visible=\(quake.isVisible)")
        for mon in monitors.monitors {
            let active = workspaces.activeWorkspaceByMonitor[mon.id] ?? "?"
            lines.append("monitor \(mon.id) active=\(active) frame=\(mon.frame)")
        }
        for (id, ws) in workspaces.workspaces.sorted(by: { $0.key < $1.key }) {
            let cols = ws.columns.map { col in col.windows.map(\.token).joined(separator: ",") }.joined(separator: " | ")
            lines.append("ws \(id) '\(ws.name)' focusCol=\(ws.focusedColumn) offset=\(ws.viewOffset) cols=[\(cols)]")
        }
        for (id, frame) in lastFrames.sorted(by: { $0.key.token < $1.key.token }) {
            lines.append("frame \(id.token) \(frame)")
        }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NSLog("%@", text)
    }


    func refreshChrome() {
        chromeRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshChromeNow()
        }
        chromeRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
}
