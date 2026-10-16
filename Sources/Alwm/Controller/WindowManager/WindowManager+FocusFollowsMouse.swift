import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC
import AlwmPluginAPI

// MARK: - Focus-follows-mouse

enum FocusFollowsMousePolicy {
    static func mouseAXPoint(quartzPoint: CGPoint?, cocoaPoint: CGPoint, mainScreenHeight: CGFloat) -> CGPoint {
        quartzPoint ?? CGPoint(x: cocoaPoint.x, y: mainScreenHeight - cocoaPoint.y)
    }

    static func shouldIgnoreUnmanagedTopWindow(topWindowNumber: Int?, isManagedWindow: Bool) -> Bool {
        guard let topWindowNumber, topWindowNumber > 0 else { return false }
        return !isManagedWindow
    }

    static func shouldKeepCurrentFocus(pointerInside: Bool, focusedPID: pid_t?, topPID: pid_t?) -> Bool {
        pointerInside && (topPID == nil || focusedPID == topPID)
    }

    static func shouldKeepCurrentWindow(
        pointerInside: Bool,
        focusedWindowNumber: Int,
        topWindowNumber: Int?,
        currentWindowHome: String? = nil,
        activeWorkspaceOnCursor: String? = nil
    ) -> Bool {
        guard pointerInside else { return false }
        if let activeWorkspaceOnCursor,
           currentWindowHome != activeWorkspaceOnCursor {
            return false
        }
        guard let topWindowNumber else { return true }
        return focusedWindowNumber == topWindowNumber
    }

    static func shouldActivateHomeWorkspace(windowHome: String?, activeWorkspaceOnCursor: String?) -> Bool {
        guard let windowHome else { return false }
        return windowHome != activeWorkspaceOnCursor
    }

    static func shouldSkipAlreadyFocusedHit(
        hitHome: String?,
        activeWorkspaceOnCursor: String?,
        focusedWindowOnCursor: WindowID?,
        axFocusedWindow: WindowID?,
        hit: WindowID
    ) -> Bool {
        // A window can still be AX-focused while it is visible on a different
        // display/space. Only skip activation when it is already focused in the
        // workspace active under the pointer.
        guard let hitHome, hitHome == activeWorkspaceOnCursor else { return false }
        return focusedWindowOnCursor == hit || axFocusedWindow == hit
    }
}

enum FocusBorderPolicy {
    static func windowMonitorID(
        liveFrame: Rect?,
        cachedFrame: Rect?,
        monitors: [MonitorInfo]
    ) -> CGDirectDisplayID? {
        // Deliberately centralized so border routing and regression tests use
        // the same live-vs-cached frame precedence.
        guard let frame = liveFrame ?? cachedFrame else { return nil }
        return monitors.first(where: {
            $0.frame.contains(pointX: frame.midX, pointY: frame.midY)
        })?.id
    }

    static func monitorID(
        focusedWorkspace: String?,
        activeWorkspaceByMonitor: [CGDirectDisplayID: String],
        focusedWindowMonitorID: CGDirectDisplayID? = nil,
        fallbackMonitorID: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        if let focusedWindowMonitorID { return focusedWindowMonitorID }
        if let focusedWorkspace,
           let monitorID = activeWorkspaceByMonitor
                .filter({ $0.value == focusedWorkspace })
                .map(\.key)
                .sorted()
                .first {
            return monitorID
        }
        return fallbackMonitorID ?? activeWorkspaceByMonitor.keys.sorted().first
    }
}

extension WindowManager {
    func mouseLocationInAXCoordinates() -> CGPoint {
        let cocoaPoint = NSEvent.mouseLocation
        let mainHeight = NSScreen.screens.first?.frame.height ?? cocoaPoint.y
        return FocusFollowsMousePolicy.mouseAXPoint(
            quartzPoint: CGEvent(source: nil)?.location,
            cocoaPoint: cocoaPoint,
            mainScreenHeight: mainHeight
        )
    }

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
            statusPopoverVisible: statusPopover.isShown
        )
    }

    func scheduleFocusWindowUnderMouse() {
        // Quake terminal / notepad / plugins / menus — never chase tiles under the cursor.
        if overlaysCaptureFocus {
            ffmWorkItem?.cancel()
            ffmWorkItem = nil
            return
        }
        let now = Date()
        // Keep cross-display/workspace focus responsive while coalescing high-rate
        // mouse events. A 40 ms gate made workspace activation feel a beat late.
        let minInterval: TimeInterval = 0.016
        if now.timeIntervalSince(ffmLastRun) >= minInterval {
            ffmWorkItem?.cancel()
            ffmWorkItem = nil
            ffmLastRun = now
            focusWindowUnderMouse()
            return
        }
        // One trailing check per interval, not one cancelled allocation per
        // mouse event. Expensive AX/CG popup queries happen in the throttled check.
        guard ffmWorkItem == nil else { return }
        let delay = minInterval - now.timeIntervalSince(ffmLastRun)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.ffmWorkItem = nil
            self.ffmLastRun = Date()
            self.focusWindowUnderMouse()
        }
        ffmWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func cgWindowUnderPoint(axX: Double, axY: Double) -> (pid: pid_t, windowNumber: Int)? {
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
                guard let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.intValue else {
                    return (pid, 0)
                }
                return (pid, windowNumber)
            }
        }
        return nil
    }

    func cgOwnerPIDUnderPoint(axX: Double, axY: Double) -> pid_t? {
        cgWindowUnderPoint(axX: axX, axY: axY)?.pid
    }

    func focusWindowUnderMouse() {
        if chromeBlocksFocusFollowsMouse() { return }
        // Column pan moves tiles under the cursor — FFM + snapView would yank offset back.
        if isColumnPanActive { return }

        let pointer = mouseLocationInAXCoordinates()
        let axX = Double(pointer.x)
        let axY = Double(pointer.y)

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
        let cursorMonitor = monitorUnderMouse() ?? primaryMonitor()
        let activeWorkspaceOnCursor = cursorMonitor.flatMap {
            workspaces.activeWorkspaceByMonitor[$0.id]
        }

        // 1) Pointer still inside the AX-focused window → never steal to a tile behind it
        //    (Finder/float “sem workspace” overlapping Discord, etc.).
        let topWindow = cgWindowUnderPoint(axX: axX, axY: axY)
        let topPID = topWindow?.pid
        if let current = currentFocus,
           current != quake.windowID || quake.isVisible,
           FocusFollowsMousePolicy.shouldKeepCurrentWindow(
               pointerInside: containsMouse(current),
               focusedWindowNumber: current.windowNumber,
               topWindowNumber: topWindow?.windowNumber == 0 ? nil : topWindow?.windowNumber,
               currentWindowHome: authoritativeHome(for: current),
               activeWorkspaceOnCursor: activeWorkspaceOnCursor
           ) {
            return
        }

        // A precise WindowServer hit avoids per-window AX frame reads, which block the
        // main thread on apps with slow accessibility trees. It also resolves a hit
        // even when its home workspace is not currently active on this display.
        if let topWindow, topWindow.windowNumber > 0 {
            let hit = WindowID(pid: topWindow.pid, windowNumber: topWindow.windowNumber)
            let trackedWindow = windowsByID[hit]
            guard !FocusFollowsMousePolicy.shouldIgnoreUnmanagedTopWindow(
                    topWindowNumber: topWindow.windowNumber,
                    isManagedWindow: trackedWindow != nil
                  ),
                  let win = trackedWindow, !win.isIgnored,
                  hit != quake.windowID || quake.isVisible,
                  !isQuakeOwned(hit) || quake.isVisible else {
                // The exact topmost surface is unmanaged (popup, sheet, utility
                // window, etc.). Never fall through to a tiled window behind it.
                return
            }
            if let cursorMonitor { primaryMonitorID = cursorMonitor.id }
            if FocusFollowsMousePolicy.shouldSkipAlreadyFocusedHit(
                hitHome: authoritativeHome(for: hit),
                activeWorkspaceOnCursor: activeWorkspaceOnCursor,
                focusedWindowOnCursor: cursorMonitor.flatMap { workspaces.activeWorkspace(for: $0.id)?.focusedWindowID },
                axFocusedWindow: axFocusedWindowID,
                hit: hit
            ) {
                refreshBorder()
                return
            }
            focusSourceIsMouse = true
            focusMouseTarget(hit, cursorMonitorID: cursorMonitor?.id)
            return
        }

        // 1b) Pointer over a popup/sheet of the focused app that spills past the tile frame
        //     (WhatsApp sticker picker, emoji panels). Raising the neighbor tile would cover
        //     the popup and steal the next click.
        let focusedPID = currentFocus?.pid
            ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let focusedPID,
           let underPID = topPID,
           let topWindow,
           underPID == focusedPID,
           !windowsByID.keys.contains(where: {
               $0.pid == underPID && $0.windowNumber == topWindow.windowNumber
           }) {
            return
        }

        // 2) Any float / scratchpad / unassigned window under the cursor beats tiled layers.
        //    Never revive a dismissed Quake scratchpad via hover.
        let looseHits = windowsByID.keys.filter { id in
            guard let win = windowsByID[id], !win.isIgnored else { return false }
            if id == quake.windowID || isQuakeOwned(id) { return false }
            if let topPID, id.pid != topPID { return false }
            if let topWindow, topWindow.windowNumber != 0,
               id.windowNumber != topWindow.windowNumber { return false }
            let loose = win.isFloating || win.isScratchpad
                || workspaces.workspaceID(containing: id) == nil
            return loose && containsMouse(id)
        }
        if let hit = looseHits.first(where: { $0 == axFocusedWindowID })
            ?? looseHits.min(by: { a, b in
                let aa = (frameOf(a)?.width ?? 0) * (frameOf(a)?.height ?? 0)
                let bb = (frameOf(b)?.width ?? 0) * (frameOf(b)?.height ?? 0)
                return aa < bb
            }) {
            if let frame = frameOf(hit),
               let monitor = monitors.monitorContaining(pointX: frame.midX, pointY: frame.midY) {
                primaryMonitorID = monitor.id
            }
            if FocusFollowsMousePolicy.shouldSkipAlreadyFocusedHit(
                hitHome: authoritativeHome(for: hit),
                activeWorkspaceOnCursor: activeWorkspaceOnCursor,
                focusedWindowOnCursor: cursorMonitor.flatMap { workspaces.activeWorkspace(for: $0.id)?.focusedWindowID },
                axFocusedWindow: axFocusedWindowID,
                hit: hit
            ) {
                refreshBorder()
                return
            }
            focusSourceIsMouse = true
            focusMouseTarget(hit, cursorMonitorID: cursorMonitor?.id)
            return
        }

        // 3) Tiled windows on the active workspace of the monitor under the cursor.
        let cursorMon = cursorMonitor
        let activeOnCursor = cursorMon.flatMap { workspaces.activeWorkspaceByMonitor[$0.id] }
        var best: (WindowID, Double)?
        for (id, frame) in lastFrames {
            guard let win = windowsByID[id], win.isTiled, !win.isIgnored else { continue }
            if let topPID, id.pid != topPID { continue }
            if let topWindow, topWindow.windowNumber != 0,
               id.windowNumber != topWindow.windowNumber { continue }
            let home = authoritativeHome(for: id)
            guard let home else { continue }
            if topWindow?.windowNumber == nil || topWindow?.windowNumber == 0,
               home != activeOnCursor { continue }
            guard frame.contains(pointX: axX, pointY: axY) else { continue }
            let area = frame.width * frame.height
            if best == nil || area < best!.1 {
                best = (id, area)
            }
        }
        guard let hit = best?.0 else { return }
        if let cursorMon { primaryMonitorID = cursorMon.id }
        if FocusFollowsMousePolicy.shouldSkipAlreadyFocusedHit(
            hitHome: authoritativeHome(for: hit),
            activeWorkspaceOnCursor: activeOnCursor,
            focusedWindowOnCursor: cursorMon.flatMap { workspaces.activeWorkspace(for: $0.id)?.focusedWindowID },
            axFocusedWindow: axFocusedWindowID,
            hit: hit
        ) {
            refreshBorder()
            return
        }
        // Final guard: still over the focused app's chrome (race with CG list).
        if let focusedPID, hit.pid != focusedPID,
           cgOwnerPIDUnderPoint(axX: axX, axY: axY) == focusedPID {
            return
        }
        focusSourceIsMouse = true
        focusMouseTarget(hit, cursorMonitorID: cursorMon?.id)
    }

    func focusMouseTarget(_ id: WindowID, cursorMonitorID: CGDirectDisplayID?) {
        let activeWorkspaceOnCursor = cursorMonitorID.flatMap { workspaces.activeWorkspaceByMonitor[$0] }
        if let home = authoritativeHome(for: id),
           FocusFollowsMousePolicy.shouldActivateHomeWorkspace(
               windowHome: home,
               activeWorkspaceOnCursor: activeWorkspaceOnCursor
           ),
           let monitor = workspaces.preferredMonitor(forWorkspace: home, monitors: monitors.monitors) {
            let cursorMonitor = cursorMonitorID.map { String($0) } ?? "?"
            logMove("ffm activate-home win=\(id.token) ws=\(home) mon=\(monitor.id) cursorMon=\(cursorMonitor)")
            focusWorkspaceWindow(id, workspaceID: home, on: monitor.id, fromMouse: true)
            return
        }
        focusWindow(id, raise: true)
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
