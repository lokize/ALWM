import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC
import AlwmPluginAPI

// MARK: - Focus-follows-mouse

extension WindowManager {
    func setupFocusFollowsMouse() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        mouseMoveEventBridge = nil
        guard configStore.config.settings.focusFollowsMouse else { return }
        // Don't capture MainActor self in the NSEvent callback.
        let bridge = AppKitEventMonitorBridge { [weak self] in
            self?.scheduleFocusWindowUnderMouse()
        }
        mouseMoveEventBridge = bridge
        mouseMonitor = bridge.installGlobal(matching: [.mouseMoved])
    }

    func chromeBlocksFocusFollowsMouse() -> Bool {
        AlwmChromeFocus.blocksFocusFollowsMouse(
            overlaysCaptureFocus: overlaysCaptureFocus,
            paletteVisible: palette.isVisible,
            overviewVisible: overview.isVisible,
            settingsVisible: settingsUI.isVisible,
            statusPopoverVisible: statusPopover.isShown,
            appTransientPopupOpen: focusedAppHasTransientPopupOpen()
        )
    }

    func focusedAppHasTransientPopupOpen() -> Bool {
        if let cached = appPopupOpenCache, Date().timeIntervalSince(cached.at) < 0.15 {
            return cached.value
        }
        let value = computeFocusedAppHasTransientPopupOpen()
        appPopupOpenCache = (Date(), value)
        return value
    }

    func computeFocusedAppHasTransientPopupOpen() -> Bool {
        let pid = axFocusedWindowID?.pid
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid else { return false }

        let monitorFrames = monitors.monitors.map(\.frame)
        for (id, win) in windowsByID {
            guard id.pid == pid, !win.isIgnored else { continue }
            if id == quake.windowID || isQuakeOwned(id) || win.isScratchpad { continue }
            guard win.isFloating || floatingOverrides.contains(id) else { continue }
            let frame = lastFrames[id] ?? win.frame
            guard OffscreenParking.isUsableOnscreenFrame(frame, monitors: monitorFrames) else { continue }
            let usable = usableAreaNear(frame)
            // Small / non-main floats = sticker pickers, emoji panels, context menus.
            if !looksLikeMainTiledWindow(frame, usable: usable) {
                return true
            }
        }

        return AlwmChromeFocus.cgProcessHasPopupLayerWindow(pid: pid)
    }

    func scheduleFocusWindowUnderMouse() {
        // Quake terminal / notepad / plugins / menus — never chase tiles under the cursor.
        if chromeBlocksFocusFollowsMouse() {
            ffmWorkItem?.cancel()
            ffmWorkItem = nil
            return
        }
        let now = Date()
        let minInterval: TimeInterval = 0.08
        if now.timeIntervalSince(ffmLastRun) >= minInterval {
            ffmLastRun = now
            focusWindowUnderMouse()
            return
        }
        ffmWorkItem?.cancel()
        let delay = minInterval - now.timeIntervalSince(ffmLastRun)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.chromeBlocksFocusFollowsMouse() { return }
            self.ffmLastRun = Date()
            self.focusWindowUnderMouse()
        }
        ffmWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cgOwnerPIDUnderPoint(axX: Double, axY: Double) -> pid_t? {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        let point = CGPoint(x: axX, y: axY)
        for info in infos {
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
                ?? (info[kCGWindowLayer as String] as? Int)
                ?? 0
            // 0 = normal; small positive = panels/popovers. Skip menubar/Dock (≈25+) and desktop.
            guard layer >= 0, layer < 25 else { continue }
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                ?? (info[kCGWindowOwnerPID as String] as? pid_t),
                  pid != selfPID
            else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { continue }
            let x = (bounds["X"] as? NSNumber)?.doubleValue ?? (bounds["X"] as? Double) ?? .nan
            let y = (bounds["Y"] as? NSNumber)?.doubleValue ?? (bounds["Y"] as? Double) ?? .nan
            let w = (bounds["Width"] as? NSNumber)?.doubleValue ?? (bounds["Width"] as? Double) ?? 0
            let h = (bounds["Height"] as? NSNumber)?.doubleValue ?? (bounds["Height"] as? Double) ?? 0
            guard w > 8, h > 8, x.isFinite, y.isFinite else { continue }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            if rect.contains(point) {
                return pid
            }
        }
        return nil
    }

    func focusWindowUnderMouse() {
        if chromeBlocksFocusFollowsMouse() { return }
        // Column pan moves tiles under the cursor — FFM + snapView would yank offset back.
        if isColumnPanActive { return }

        let loc = NSEvent.mouseLocation
        let mainHeight = Double(NSScreen.screens.first?.frame.height ?? loc.y)
        let axX = Double(loc.x)
        let axY = mainHeight - Double(loc.y)

        func frameOf(_ id: WindowID) -> Rect? {
            // Hidden quake must never use a stale on-screen lastFrames hit target.
            if id == quake.windowID, !quake.isVisible { return nil }
            return ax.currentFrame(of: id) ?? lastFrames[id] ?? windowsByID[id]?.frame
        }
        func containsMouse(_ id: WindowID) -> Bool {
            guard let f = frameOf(id), f.width > 20, f.height > 20 else { return false }
            return f.contains(pointX: axX, pointY: axY)
        }

        let currentFocus = axFocusedWindowID ?? ax.frontmostFocusedWindowID() ?? focusedWindowID()

        // 1) Pointer still inside the AX-focused window → never steal to a tile behind it
        //    (Finder/float “sem workspace” overlapping Discord, etc.).
        if let current = currentFocus,
           current != quake.windowID || quake.isVisible,
           containsMouse(current) {
            return
        }

        // 1b) Pointer over a popup/sheet of the focused app that spills past the tile frame
        //     (WhatsApp sticker picker, emoji panels). Raising the neighbor tile would cover
        //     the popup and steal the next click.
        let focusedPID = currentFocus?.pid
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let focusedPID,
           let underPID = cgOwnerPIDUnderPoint(axX: axX, axY: axY),
           underPID == focusedPID {
            return
        }

        // 2) Any float / scratchpad / unassigned window under the cursor beats tiled layers.
        //    Never revive a dismissed Quake scratchpad via hover.
        let looseHits = windowsByID.keys.filter { id in
            guard let win = windowsByID[id], !win.isIgnored else { return false }
            if id == quake.windowID || isQuakeOwned(id) { return false }
            let loose = win.isFloating || win.isScratchpad
                || workspaces.workspaceID(containing: id) == nil
            return loose && containsMouse(id)
        }
        if let hit = looseHits.first(where: { $0 == axFocusedWindowID })
            ?? looseHits.max(by: { a, b in
                let aa = (frameOf(a)?.width ?? 0) * (frameOf(a)?.height ?? 0)
                let bb = (frameOf(b)?.width ?? 0) * (frameOf(b)?.height ?? 0)
                return aa < bb
            }) {
            if focusedWindowID() == hit || axFocusedWindowID == hit { return }
            focusSourceIsMouse = true
            focusWindow(hit, raise: true)
            return
        }

        // 3) Tiled windows on the active workspace of the monitor under the cursor.
        let cursorMon = monitorUnderMouse() ?? primaryMonitor()
        let activeOnCursor = cursorMon.flatMap { workspaces.activeWorkspaceByMonitor[$0.id] }
        var best: (WindowID, Double)?
        for (id, frame) in lastFrames {
            guard let win = windowsByID[id], win.isTiled, !win.isIgnored else { continue }
            let home = authoritativeHome(for: id)
            guard let home, let activeOnCursor, home == activeOnCursor else { continue }
            guard frame.contains(pointX: axX, pointY: axY) else { continue }
            let area = frame.width * frame.height
            if best == nil || area < best!.1 {
                best = (id, area)
            }
        }
        guard let hit = best?.0 else { return }
        if focusedWindowID() == hit || axFocusedWindowID == hit { return }
        // Final guard: still over the focused app's chrome (race with CG list).
        if let focusedPID, hit.pid != focusedPID,
           cgOwnerPIDUnderPoint(axX: axX, axY: axY) == focusedPID {
            return
        }
        focusSourceIsMouse = true
        focusWindow(hit)
    }

    func maybeWarpCursor(to id: WindowID) {
        guard !overlaysCaptureFocus else { return }
        guard configStore.config.settings.moveMouseToFocusedWindow, !focusSourceIsMouse else { return }
        guard let frame = lastFrames[id] else { return }
        let mainH = Double(NSScreen.screens.first?.frame.height ?? 900)
        let cocoaY = mainH - frame.midY
        warpCursor(to: CGPoint(x: frame.midX, y: cocoaY))
    }

    func warpCursor(to point: CGPoint) {
        let event = CGEvent(source: nil)
        event?.type = .mouseMoved
        CGWarpMouseCursorPosition(point)
    }

}
