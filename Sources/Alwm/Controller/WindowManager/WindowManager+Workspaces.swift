import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC
import AlwmPluginAPI

// MARK: - Workspaces — switch, move, focus, bundle heal

extension WindowManager {
    func cycleWorkspace(by delta: Int, on monitorID: CGDirectDisplayID) {
        guard let idx = workspaces.monitorIndex(of: monitorID, in: monitors.monitors) else { return }
        let pool = workspaces.definitionsVisible(onMonitorIndex: idx).map(\.id)
        guard !pool.isEmpty else { return }
        let current = workspaces.activeWorkspaceByMonitor[monitorID] ?? pool[0]
        guard let currentIndex = pool.firstIndex(of: current) else {
            switchWorkspace(id: pool[0], on: monitorID)
            return
        }
        let nextIndex = (currentIndex + delta + pool.count * 10) % pool.count
        switchWorkspace(id: pool[nextIndex], on: monitorID)
    }

    func switchWorkspace(id: String, on monitorID: CGDirectDisplayID, restoreLayout: Bool = false) {
        guard workspaces.workspaces[id] != nil else { return }

        // Prefer pinned monitor; else the caller's; else any monitor that lists this workspace.
        let preferred = workspaces.preferredMonitor(forWorkspace: id, monitors: monitors.monitors)?.id
        let candidates: [CGDirectDisplayID] = [preferred, monitorID].compactMap { $0 }
            + monitors.monitors.map(\.id)
        let targetMonitorID = candidates.first { monID in
            guard let idx = workspaces.monitorIndex(of: monID, in: monitors.monitors) else { return false }
            return workspaces.isWorkspace(id, allowedOnMonitorIndex: idx)
        }
        guard let targetMonitorID else {
            refreshChrome()
            return
        }

        let current = workspaces.activeWorkspaceByMonitor[targetMonitorID]
        guard current != id else {
            refreshChrome()
            return
        }

        // Prevent AX focus / ingest / geometry loops during the switch.
        suppressWorkspaceFollowUntil = Date().addingTimeInterval(2.5)
        suppressIngestReassignUntil = Date().addingTimeInterval(2.5)
        suppressGeometryEnforce(for: 1.2)
        primaryMonitorID = targetMonitorID
        workspaceSwitchGeneration &+= 1
        let switchGeneration = workspaceSwitchGeneration

        // Snapshot order before switching so sticky restore stays accurate.
        persistRuntimeState()
        workspaces.switchWorkspace(id: id, on: targetMonitorID, monitors: monitors.monitors, syncAllMonitors: false)
        runtimeState.setLastWorkspace(id, on: targetMonitorID)
        if restoreLayout {
            // Cold start / recovery only — routine switches keep in-memory columns.
            // Restoring from disk every switch was stealing windows into WS1 via fuzzy bundle match.
            restoreWorkspaceLayout(for: id)
            retileAccidentalFloats(forceClearOverrides: false)
            persistRuntimeState()
        } else {
            // Switch-back: re-apply saved column order/widths for windows already sticky here.
            // Without this, a soft-missing Safari column collapses to one full-width stack
            // (Discord over WhatsApp) until mouse hover forces a relayout.
            refreshWorkspaceLayoutFromSnapshot(for: id)
        }
        // Clear soft-missing before heal so destination tiles aren't ejected from columns.
        if let ws = workspaces.workspaces[id] {
            for wid in ws.columns.flatMap(\.windows) {
                missingScanCounts.removeValue(forKey: wid)
                if ax.isMinimized(wid) {
                    ax.setMinimized(false, id: wid)
                }
            }
        }
        healStaleColumnEntries()
        // Routine switches keep in-memory columns (merges, move.left/right, widths).
        animator.stop()
        border.hide()

        visibilityForceReveal = true
        lastVisibilitySignature = nil
        applyWorkspaceVisibility(animated: false)
        ensureQuakeFullyHidden()

        if let mon = monitors.monitors.first(where: { $0.id == targetMonitorID }) {
            // Force column frames now — visibility alone can skip via isSettled / stale signature.
            applyWorkspaceTileLayout(id, on: mon, forceReveal: true, skipHeal: true)
            // One immediate enforce — deferred settles handle Safari/Electron lag without
            // scheduling another rewrite wave at +0.12s on every switch.
            if !overlaysCaptureFocus {
                enforceActiveTileFrames()
                applyAllActiveStackColumns()
            }

            let ws = workspaces.activeWorkspace(for: targetMonitorID)
            // Focus a window that actually belongs to this workspace (skip stale column ghosts).
            let focused: WindowID? = {
                if let fid = ws?.focusedWindowID {
                    let home = authoritativeHome(for: fid)
                    if home == nil || home == id { return fid }
                }
                return ws?.columns.flatMap(\.windows).first { authoritativeHome(for: $0) == id }
            }()
            if let focused {
                if !overlaysCaptureFocus {
                    ax.focus(focused)
                    maybeWarpCursor(to: focused)
                }
            } else if configStore.config.settings.warpCursorOnEmptyWorkspace, !overlaysCaptureFocus {
                let mainH = Double(NSScreen.screens.first?.frame.height ?? CGFloat(mon.frame.height))
                warpCursor(to: CGPoint(x: mon.frame.midX, y: mainH - mon.frame.midY))
            }
        }
        // Single delayed settle instead of 180ms + 420ms full rewrites + 4 Electron shrink/grow nudges
        // (that sequence made tiles flicker/resize for ~1–3s on every workspace switch).
        scheduleWorkspaceSwitchSettle(workspaceID: id, generation: switchGeneration)
        refreshChrome()
    }

    /// After a switch: one calm follow-up if AX hasn't accepted tiles yet; optional Electron nudge only when needed.
    func scheduleWorkspaceSwitchSettle(workspaceID: String, generation: UInt64) {
        let monitorsSnapshot = monitors.monitors.map(\.frame)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard let self, self.workspaceSwitchGeneration == generation else { return }
            guard self.workspaces.activeWorkspaceByMonitor.values.contains(workspaceID) else { return }

            let activeLater = Set(self.workspaces.activeWorkspaceByMonitor.values)
            self.settleParkedWindows(activeIDs: activeLater, monitors: monitorsSnapshot)
            self.ensureQuakeFullyHidden()

            guard let mon = self.monitors.monitors.first(where: {
                self.workspaces.activeWorkspaceByMonitor[$0.id] == workspaceID
            }) else {
                self.refreshBorder()
                self.refreshChrome()
                return
            }

            if !self.workspaceTilesSettled(workspaceID: workspaceID, on: mon) {
                self.suppressGeometryEnforce(for: 0.6)
                self.visibilityForceReveal = true
                self.applyWorkspaceTileLayout(workspaceID, on: mon, forceReveal: true, skipHeal: true)
                if !self.overlaysCaptureFocus {
                    self.enforceActiveTileFrames()
                    self.applyAllActiveStackColumns()
                }
            }

            // Chromium only — and only if still drifting after the settle pass.
            if self.workspaceNeedsElectronSettle(workspaceID),
               !self.workspaceTilesSettled(workspaceID: workspaceID, on: mon) {
                self.nudgeElectronTileReflow(workspaceID: workspaceID)
            }

            self.refreshBorder()
            self.refreshChrome()
        }

        // Late Chromium pass (composer/webview) — skip entirely when nothing needs it.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard let self, self.workspaceSwitchGeneration == generation else { return }
            guard self.workspaces.activeWorkspaceByMonitor.values.contains(workspaceID) else { return }
            guard self.workspaceNeedsElectronSettle(workspaceID) else { return }
            guard let mon = self.monitors.monitors.first(where: {
                self.workspaces.activeWorkspaceByMonitor[$0.id] == workspaceID
            }) else { return }
            guard !self.workspaceTilesSettled(workspaceID: workspaceID, on: mon) else { return }
            self.suppressGeometryEnforce(for: 0.5)
            self.clampActiveTilesToUsable(workspaceID: workspaceID, monitor: mon)
            self.nudgeElectronTileReflow(workspaceID: workspaceID)
            self.refreshBorder()
        }
    }

    func workspaceNeedsElectronSettle(_ workspaceID: String) -> Bool {
        guard let ws = workspaces.workspaces[workspaceID] else { return false }
        return ws.columns.flatMap(\.windows).contains { id in
            guard let win = windowsByID[id], win.isTiled, !win.isIgnored else { return false }
            return needsElectronReflowNudge(win)
        }
    }

    func workspaceTilesSettled(workspaceID: String, on monitor: MonitorInfo) -> Bool {
        guard let ws = workspaces.workspaces[workspaceID] else { return true }
        let monitorFrames = monitors.monitors.map(\.frame)
        let assignments = engine.computeFrames(
            workspace: ws,
            windows: windowsByID,
            monitor: monitor.layoutFrame,
            active: true,
            stackExcluded: stackExcludedFromLayout(),
            layoutExcluded: layoutExcludedWindowIDs(for: workspaceID, monitor: monitor)
        )
        for a in assignments where a.visible {
            guard windowsByID[a.windowID]?.isTiled == true else { continue }
            guard authoritativeHome(for: a.windowID) == workspaceID else { continue }
            if ax.isMinimized(a.windowID) { return false }
            if !ax.isSettled(id: a.windowID, frame: a.frame, monitors: monitorFrames) {
                return false
            }
        }
        return true
    }

    func focusWorkspaceWindow(_ windowID: WindowID, workspaceID: String, on monitorID: CGDirectDisplayID) {
        // Some windows (Electron/Safari) briefly disappear from AX during reveal/stack ops.
        // For bar/menu selection we should *not* treat this as a closed ghost; instead,
        // do one soft-rescan and then attempt reveal/focus.
        var targetID = windowID
        var live = Set(ax.currentWindows.map(\.id))

        // Token churn: the menu item token may be stale by the time you click.
        // Resolve to a live window ID within the requested workspace.
        if windowsByID[targetID] == nil || (!live.contains(targetID) && missingScanCounts[targetID] != nil) {
            if let resolved = resolveLiveWindowID(for: targetID, preferredWS: workspaceID) {
                if resolved != targetID {
                    logMove(
                        "bar-focus resolve stale win=\(targetID.token) → live=\(resolved.token) ws=\(workspaceID) mon=\(monitorID)"
                    )
                    targetID = resolved
                    live = Set(ax.currentWindows.map(\.id))
                }
            }
        }

        guard windowsByID[targetID] != nil else {
            pruneDeadTrackedWindows()
            refreshChrome()
            return
        }
        let isSoftMissing = missingScanCounts[targetID] != nil
        if !live.contains(targetID), isSoftMissing {
            logMove(
                "bar-focus soft-missing — req win=\(targetID.token) ws=\(workspaceID) mon=\(monitorID) liveContains=\(live.contains(targetID)) missingCount=\(missingScanCounts[targetID] ?? -1)"
            )
            // Soft-missing: retry once.
            ax.scanAll()
            ingest(windows: ax.currentWindows)
            live = Set(ax.currentWindows.map(\.id))
        }

        // Prefer the window's sticky home over the chip that was clicked
        // (Safari on WS5 must switch to WS5 even when the menu opened from WS1).
        let home = authoritativeHome(for: targetID)
            ?? (workspaces.workspaces[workspaceID] != nil ? workspaceID : nil)
            ?? workspaces.activeWorkspaceByMonitor[monitorID]
            ?? ""
        if !live.contains(targetID) {
            logMove(
                "bar-focus still-not-live — req win=\(targetID.token) chipWS=\(workspaceID) home=\(home) mon=\(monitorID)"
            )
        }
        guard !home.isEmpty, workspaces.workspaces[home] != nil else {
            focusSourceIsMouse = false
            revealBeforeFocus(targetID)
            focusWindow(targetID, raise: true)
            refreshChrome()
            return
        }

        let placeOn = workspaces.preferredMonitor(forWorkspace: home, monitors: monitors.monitors)?.id
            ?? monitorID
        let active = workspaces.activeWorkspaceByMonitor[placeOn]
        let didSwitch = active != home
        if didSwitch {
            logMove(
                "bar-focus switch win=\(targetID.token) → ws=\(home) mon=\(placeOn) (from chipWS=\(workspaceID))"
            )
            switchWorkspace(id: home, on: placeOn, restoreLayout: false)
        }

        let mon = monitors.monitors.first(where: { $0.id == placeOn })
            ?? workspaces.preferredMonitor(forWorkspace: home, monitors: monitors.monitors)
            ?? primaryMonitor()
        if let mon, !didSwitch {
            prepareWorkspaceLayoutForDisplay(home, monitor: mon)
        }

        // Point column focus at this window (keeps other windows and their frames).
        if var ws = workspaces.workspaces[home], let loc = engine.locate(targetID, in: ws) {
            ws.focusedColumn = loc.col
            ws.focusedWindowInColumn[loc.col] = loc.row
            ws.viewOffset = 0
            workspaces.setWorkspace(ws)
        }

        let win = windowsByID[targetID]
        let rules = configStore.config.rules
        let isFloat = win?.isFloating == true || win?.isScratchpad == true
            || floatingOverrides.contains(targetID)
            || (win.map { AppRules.forcesFloat(rules: rules, window: $0) } ?? false)
            || workspaces.workspaceID(containing: targetID) == nil
        markFloatRevealProtected(targetID)

        focusSourceIsMouse = false
        revealBeforeFocus(targetID)
        focusWindow(targetID, raise: true)
        if isFloat {
            refreshChrome()
            return
        }
        if !didSwitch {
            relayout(animated: false)
        }
        healUnusableFocusedFrame(targetID)
        refreshChrome()
    }

    func settleParkedWindows(activeIDs: Set<String>, monitors: [Rect]) {
        ensureQuakeFullyHidden()
        guard !isApplyingVisibility else { return }
        ax.withMutation {
            for (id, win) in windowsByID where !win.isIgnored {
                if id == quake.windowID || isQuakeOwned(id) { continue }
                let home = authoritativeHome(for: id)
                let onActive = home.map { isHomeActiveOnAnyMonitor($0) } ?? false
                if onActive, let home {
                    if isFloatRevealProtected(id) {
                        if let layoutMonitor = primaryMonitor() {
                            let live = liveFrameForVisibility(id) ?? win.frame
                            let frame = floatFrameForActiveHome(
                                id: id, home: home, live: live, layoutMonitor: layoutMonitor
                            )
                            ax.reveal(frame: frame, id: id)
                            lastFrames[id] = frame
                        }
                        continue
                    }
                    if let live = liveFrameForVisibility(id),
                       frameLeaksWrongMonitor(home: home, frame: live) {
                        ax.reparkIfLeaking(
                            id: id,
                            monitors: monitors,
                            allowMinimize: allowMinimizeDespiteSibling(id)
                        )
                    } else if win.isTiled, let frame = lastFrames[id],
                              !ax.isSettled(id: id, frame: frame, monitors: monitors) {
                        ax.reveal(frame: frame, id: id)
                    }
                } else {
                    guard let live = liveFrameForVisibility(id) else { continue }
                    var siblingVisible = false
                    for other in windowsByID.keys where other.pid == id.pid && other != id {
                        let home = windowWorkspace[other] ?? workspaces.workspaceID(containing: other)
                        if let home, activeIDs.contains(home) {
                            siblingVisible = true
                            break
                        }
                    }
                    let escalate = !siblingVisible || allowsPerWindowMinimize(id)
                    if OffscreenParking.isUsableOnscreenFrame(live, monitors: monitors) {
                        var parkFrame = savedFrames[id] ?? live
                        parkFrame.x = OffscreenParking.parkOrigin(monitors: monitors, preferred: nil).x
                        parkFrame.y = OffscreenParking.parkOrigin(monitors: monitors, preferred: nil).y
                        if escalate {
                            ax.parkAndHide(frame: parkFrame, id: id, monitors: monitors)
                        } else {
                            ax.parkOffscreen(frame: parkFrame, id: id, monitors: monitors)
                        }
                    } else {
                        ax.reparkIfLeaking(id: id, monitors: monitors, allowMinimize: escalate)
                    }
                }
            }
        }
        ax.suppressNotifications(for: 0.25)
    }

    func moveFocusedToWorkspace(_ workspaceID: String, follow: Bool = false) {
        if windowsByID.isEmpty || (axFocusedWindowID == nil && focusedWindowID() == nil) {
            ax.scanAll()
            ingest(windows: ax.currentWindows)
        }
        guard let id = axFocusedWindowID
            ?? ax.frontmostFocusedWindowID()
            ?? focusedWindowID()
        else {
            NSLog("ALWM: move.to.workspace.%@ — nenhuma janela focada", workspaceID)
            return
        }
        moveWindow(requestedID: id, to: workspaceID, follow: follow)
    }

    func applyWorkspaceTileLayout(
        _ workspaceID: String,
        on monitor: MonitorInfo,
        forceReveal: Bool = true,
        movedID: WindowID? = nil,
        skipHeal: Bool = false
    ) {
        guard workspaces.workspaces[workspaceID] != nil else { return }
        let layoutMon = displayMonitor(forHome: workspaceID, fallback: monitor)
        beginLayoutPass()
        animator.stop(finish: true)
        syncColumnTilesNotFloat()
        let ejectedWS = ejectWindowsListedOutsideStickyHome()
        if !ejectedWS.isEmpty {
            persistRuntimeState(forceWorkspaceLayouts: ejectedWS.union([workspaceID]))
        }
        if !skipHeal, Date() >= suppressIngestReassignUntil {
            healStaleColumnEntries()
            reinsertOrphanTiles()
        }
        if var ws = workspaces.workspaces[workspaceID] {
            let usable = engine.usableArea(monitor: layoutMon.layoutFrame)
            let contentW = engine.niri.contentWidth(workspace: ws, usable: usable)
            if contentW > usable.width + 1.0 {
                engine.fitAllColumnsOnScreen(workspace: &ws, usable: usable)
                workspaces.setWorkspace(ws)
            } else {
                prepareWorkspaceLayoutForDisplay(workspaceID, monitor: layoutMon)
            }
        } else {
            prepareWorkspaceLayoutForDisplay(workspaceID, monitor: layoutMon)
        }
        guard let layoutWS = workspaces.workspaces[workspaceID] else { return }
        let active = isHomeActiveOnAnyMonitor(workspaceID)
        let assignments = engine.computeFrames(
            workspace: layoutWS,
            windows: windowsByID,
            monitor: layoutMon.layoutFrame,
            active: active,
            stackExcluded: stackExcludedFromLayout(),
            layoutExcluded: layoutExcludedWindowIDs(for: workspaceID, monitor: layoutMon)
        )
        let applied = applyWorkspaceColumnTileFrames(
            workspaceID: workspaceID,
            monitor: layoutMon,
            assignments: assignments,
            forceReveal: forceReveal
        )
        ax.suppressNotifications(for: 0.35)
        if let movedID {
            let slot = engine.locate(movedID, in: layoutWS).map { "\($0.col):\($0.row)" } ?? "orphan"
            NSLog(
                "ALWM: tile-layout ws=%@ moved=%@ slot=%@ applied=%d/%d active=%@",
                workspaceID,
                movedID.token,
                slot,
                applied,
                assignments.count,
                active ? "yes" : "no"
            )
        }
    }

    func applyForcedTileFrame(for id: WindowID) {
        guard let home = authoritativeHome(for: id),
              let win = windowsByID[id], !win.isIgnored else { return }
        guard win.isTiled || workspaces.workspaceID(containing: id) != nil else { return }
        let mon = displayMonitor(forHome: home, fallback: primaryMonitor() ?? monitors.monitors[0])
        prepareWorkspaceLayoutForDisplay(home, monitor: mon)
        guard let layoutWS = workspaces.workspaces[home] else { return }
        let active = isHomeActiveOnAnyMonitor(home)
        guard let assignment = engine.computeFrames(
            workspace: layoutWS,
            windows: windowsByID,
            monitor: mon.layoutFrame,
            active: active,
            stackExcluded: stackExcludedFromLayout(),
            layoutExcluded: layoutExcludedWindowIDs(for: home, monitor: mon)
        ).first(where: { $0.windowID == id }) else { return }
        guard assignment.visible || active else { return }
        let target = clampHorizontalTileFrame(assignment.frame, for: id)
        ax.withMutation {
            if ax.isMinimized(id) { ax.setMinimized(false, id: id) }
            ax.forceFrame(target, id: id)
            if let live = ax.currentFrame(of: id),
               !OffscreenParking.isUsableOnscreenFrame(live, monitors: monitors.monitors.map(\.frame)) {
                ax.forceFrame(target, id: id)
            }
            lastFrames[id] = ax.currentFrame(of: id) ?? target
        }
    }

    func isMoveProtectedTile(_ id: WindowID) -> Bool {
        if let until = forcedTiledUntil[id], Date() < until { return true }
        if Date() < suppressIngestReassignUntil, windowWorkspace[id] != nil { return true }
        return false
    }

    func isFloatRevealProtected(_ id: WindowID) -> Bool {
        guard let win = windowsByID[id], !win.isIgnored else { return false }
        let isFloat = win.isFloating || win.isScratchpad || floatingOverrides.contains(id)
        guard isFloat else { return false }
        guard let home = authoritativeHome(for: id), isHomeActiveOnAnyMonitor(home) else { return false }
        if let until = forcedFloatVisibleUntil[id], Date() < until { return true }
        if Date().timeIntervalSince(windowFirstTrackedAt[id] ?? .distantPast) < floatRevealGrace { return true }
        if axFocusedWindowID == id || ax.frontmostFocusedWindowID() == id { return true }
        return false
    }

    func isTileRevealProtected(_ id: WindowID) -> Bool {
        guard let win = windowsByID[id], win.isTiled, !win.isIgnored else { return false }
        guard !win.isFloating, !win.isScratchpad, !floatingOverrides.contains(id) else { return false }
        guard let home = authoritativeHome(for: id), isHomeActiveOnAnyMonitor(home) else { return false }
        if axFocusedWindowID == id || ax.frontmostFocusedWindowID() == id { return true }
        return Date().timeIntervalSince(windowFirstTrackedAt[id] ?? .distantPast) < newWindowColumnGrace
    }

    func isVisibilityRevealProtected(_ id: WindowID) -> Bool {
        isFloatRevealProtected(id) || isTileRevealProtected(id)
    }

    func markFloatRevealProtected(_ id: WindowID, seconds: TimeInterval? = nil) {
        guard windowsByID[id] != nil else { return }
        let duration = seconds ?? floatRevealGrace
        forcedFloatVisibleUntil[id] = Date().addingTimeInterval(duration)
        if windowFirstTrackedAt[id] == nil {
            windowFirstTrackedAt[id] = Date()
        }
    }

    func revealActiveFloats(ids: Set<WindowID>) {
        guard !ids.isEmpty, let layoutMonitor = primaryMonitor() else { return }
        let allMonitorFrames = monitors.monitors.map(\.frame)
        ax.withMutation {
            for id in ids {
                guard let win = windowsByID[id], !win.isIgnored else { continue }
                guard let home = authoritativeHome(for: id), isHomeActiveOnAnyMonitor(home) else { continue }
                let live = ax.currentFrame(of: id) ?? win.frame
                let frame = floatFrameForActiveHome(
                    id: id, home: home, live: live, layoutMonitor: layoutMonitor
                )
                ax.reveal(frame: frame, id: id)
                if OffscreenParking.isUsableOnscreenFrame(frame, monitors: allMonitorFrames) {
                    savedFrames[id] = frame
                }
                lastFrames[id] = ax.currentFrame(of: id) ?? frame
            }
        }
        refreshBorder()
    }

    func logMove(_ message: String) {
        NSLog("ALWM: %@", message)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = ConfigPaths.moveLog
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func windowRef(for id: WindowID) -> RuntimeStateStore.WindowRef {
        if let win = windowsByID[id] { return RuntimeStateStore.WindowRef(window: win) }
        for layout in runtimeState.snapshot.workspaceLayouts.values {
            for ref in layout.columns.flatMap(\.windows) + layout.floating where ref.token == id.token {
                return ref
            }
        }
        return RuntimeStateStore.WindowRef(token: id.token)
    }

    func resolveLiveWindowID(for id: WindowID, preferredWS: String?) -> WindowID? {
        // Keep the exact token whenever we still track it (incl. parked inactive-WS windows).
        if windowsByID[id] != nil {
            if ax.currentFrame(of: id) != nil
                || workspaces.workspaceID(containing: id) != nil
                || windowWorkspace[id] != nil {
                return id
            }
        }

        if windowsByID[id] == nil {
            ax.scanAll()
            ingest(windows: ax.currentWindows)
        }
        if windowsByID[id] != nil {
            if ax.currentFrame(of: id) != nil
                || workspaces.workspaceID(containing: id) != nil
                || windowWorkspace[id] != nil {
                return id
            }
        }

        let ref = windowRef(for: id)
        let home = preferredWS
            ?? windowWorkspace[id]
            ?? runtimeState.assignment(for: id)
            ?? workspaces.workspaceID(containing: id)
            ?? ""
        let liveByToken = Dictionary(uniqueKeysWithValues: windowsByID.keys.map { ($0.token, $0) })
        if !home.isEmpty,
           let live = resolveLiveWindow(ref, preferredWS: home, liveByToken: liveByToken, used: []) {
            return live
        }

        if let bid = ref.bundleID, !bid.isEmpty {
            let candidates = windowsByID.values.filter {
                $0.bundleID == bid
                    && $0.id.pid == id.pid
                    && !$0.isIgnored
                    && missingScanCounts[$0.id] == nil
            }
            // Multi-window Safari/Cursor: never steal a sibling via "focused" / "first visible".
            if candidates.count > 1 {
                let refTitle = Self.normalizedWindowTitle(ref.title)
                if !refTitle.isEmpty {
                    let titleHits = candidates.filter {
                        let t = Self.normalizedWindowTitle($0.title)
                        return t == refTitle || Self.titlesLooselyMatch(refTitle, t)
                    }
                    if titleHits.count == 1 { return titleHits[0].id }
                }
                if let focused = axFocusedWindowID,
                   candidates.contains(where: { $0.id == focused }) {
                    return focused
                }
                logMove("move resolve ambiguous bundle=\(bid) req=\(id.token) candidates=\(candidates.map(\.id.token).joined(separator: ","))")
                return nil
            }
            if candidates.count == 1 { return candidates[0].id }
        }
        return windowsByID[id] != nil ? id : nil
    }

    func applyStickyHomeForMove(_ workspaceID: String, win: ManagedWindow, live: WindowID) {
        windowWorkspace[live] = workspaceID
        runtimeState.setAssignment(workspaceID, for: live)
        guard let bid = win.bundleID, !bid.isEmpty else { return }

        let siblingLive = windowsByID.keys.filter {
            $0 != live && $0.pid == live.pid && windowsByID[$0]?.bundleID == bid
                && missingScanCounts[$0] == nil
        }
        // Bundle→WS map is only meaningful for single-instance apps.
        if siblingLive.isEmpty, isSingleBundleInstance(bid, pid: live.pid) {
            runtimeState.setBundleAssignment(workspaceID, for: bid)
        }

        // Never yank other live windows. Only migrate ghost tokens of the same single instance.
        guard siblingLive.isEmpty else {
            logMove(
                "move sticky keep-siblings live=\(live.token) → ws=\(workspaceID) siblings=\(siblingLive.map(\.token).sorted().joined(separator: ","))"
            )
            return
        }
        guard isSingleBundleInstance(bid, pid: live.pid) else { return }

        for (token, _) in runtimeState.snapshot.windowWorkspace {
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, Int32(parts[0]) == live.pid else { continue }
            if let wid = windowsByID.keys.first(where: { $0.token == token }),
               windowsByID[wid]?.bundleID == bid {
                // Skip any live sibling that appeared mid-loop.
                if wid != live, missingScanCounts[wid] == nil { continue }
                windowWorkspace[wid] = workspaceID
                runtimeState.setAssignment(workspaceID, for: wid)
            } else if let winNum = Int(parts[1]) {
                runtimeState.setAssignment(
                    workspaceID,
                    for: WindowID(pid: live.pid, windowNumber: winNum)
                )
            }
        }
    }

    func purgeStaleBundleTokens(
        keeping live: WindowID,
        bundleID: String,
        workspaceScope: String? = nil
    ) {
        let liveHome = workspaceScope
            ?? workspaceHome(for: live)
        let liveAX = Set(ax.currentWindows.map(\.id))
        let stale = windowsByID.keys.filter { key in
            guard key != live, key.pid == live.pid, windowsByID[key]?.bundleID == bundleID else {
                return false
            }
            // Preserve every other live window of this app.
            if isLiveBundleSibling(key, liveAX: liveAX) { return false }
            if let scope = liveHome {
                return workspaceHome(for: key) == scope
            }
            return true
        }
        for old in stale {
            workspaces.removeWindowEverywhere(old)
            windowWorkspace.removeValue(forKey: old)
            runtimeState.setAssignment(nil, for: old)
            forcedTiledUntil.removeValue(forKey: old)
            floatingOverrides.remove(old)
            savedFrames.removeValue(forKey: old)
            lastFrames.removeValue(forKey: old)
            missingScanCounts.removeValue(forKey: old)
            windowFirstTrackedAt.removeValue(forKey: old)
            windowsByID.removeValue(forKey: old)
        }
    }

    func bundleInstanceScore(_ id: WindowID) -> Int {
        let liveAX = Set(ax.currentWindows.map(\.id))
        var score = 0
        if liveAX.contains(id) { score += 100 }
        if ax.currentFrame(of: id) != nil { score += 50 }
        if !ax.isMinimized(id) { score += 40 }
        if missingScanCounts[id] == nil { score += 30 }
        if workspaces.workspaceID(containing: id) != nil { score += 10 }
        if id == axFocusedWindowID || id == ax.frontmostFocusedWindowID() { score += 200 }
        if let home = workspaceHome(for: id), isHomeActiveOnAnyMonitor(home) { score += 80 }
        return score
    }

    func workspaceHome(for id: WindowID) -> String? {
        if let sticky = windowWorkspace[id], workspaces.workspaces[sticky] != nil { return sticky }
        if let saved = runtimeState.assignment(for: id), workspaces.workspaces[saved] != nil { return saved }
        return workspaces.workspaceID(containing: id)
    }

    func preferredBundleInstanceToken(among ids: [WindowID], bundleID: String) -> WindowID? {
        guard !ids.isEmpty else { return nil }
        if ids.count == 1 { return ids[0] }
        return ids.max(by: { bundleInstanceScore($0) < bundleInstanceScore($1) })
    }

    func isLiveBundleSibling(_ id: WindowID, liveAX: Set<WindowID>) -> Bool {
        liveAX.contains(id)
            && windowsByID[id] != nil
            && ax.currentFrame(of: id) != nil
            && !ax.isMinimized(id)
            && missingScanCounts[id] == nil
    }

    func ejectStaleBundleInstance(from workspaceID: String, keeping id: WindowID) {
        guard let win = windowsByID[id], let bid = win.bundleID, !bid.isEmpty,
              let ws = workspaces.workspaces[workspaceID] else { return }
        let liveAX = Set(ax.currentWindows.map(\.id))
        let siblings = ws.columns.flatMap(\.windows).filter { other in
            other != id && other.pid == id.pid && windowsByID[other]?.bundleID == bid
        }
        let ghosts = siblings.filter { !isLiveBundleSibling($0, liveAX: liveAX) }
        guard !ghosts.isEmpty else { return }
        // Only remove ghosts — keep every live sibling tile.
        for ghost in ghosts {
            workspaces.removeWindowEverywhere(ghost)
            windowWorkspace.removeValue(forKey: ghost)
            runtimeState.setAssignment(nil, for: ghost)
            forcedTiledUntil.removeValue(forKey: ghost)
            floatingOverrides.remove(ghost)
            savedFrames.removeValue(forKey: ghost)
            lastFrames.removeValue(forKey: ghost)
            missingScanCounts.removeValue(forKey: ghost)
            windowFirstTrackedAt.removeValue(forKey: ghost)
            windowsByID.removeValue(forKey: ghost)
        }
        _ = bid // keep intent clear for future scoped purge helpers
    }

    func dedupeBundleInstanceTokens() -> Set<String> {
        var affected: Set<String> = []
        var byWSKey: [String: [WindowID]] = [:]
        for (id, win) in windowsByID {
            guard !win.isIgnored, let bid = win.bundleID, !bid.isEmpty,
                  let home = workspaceHome(for: id), !home.isEmpty else { continue }
            byWSKey["\(home)|\(bid)|\(id.pid)", default: []].append(id)
        }
        let liveAX = Set(ax.currentWindows.map(\.id))
        for (key, ids) in byWSKey where ids.count > 1 {
            let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            let wsID = String(parts[0])
            let bid = String(parts[1])
            let liveIds = ids.filter { isLiveBundleSibling($0, liveAX: liveAX) }
            let ghosts = ids.filter { !liveIds.contains($0) }
            // If two+ live windows exist, this is a real multi-window app — keep all live.
            guard !ghosts.isEmpty, !liveIds.isEmpty else { continue }
            guard let keeper = preferredBundleInstanceToken(among: liveIds, bundleID: bid) else { continue }
            for ghost in ghosts {
                workspaces.removeWindowEverywhere(ghost)
                windowWorkspace.removeValue(forKey: ghost)
                runtimeState.setAssignment(nil, for: ghost)
                forcedTiledUntil.removeValue(forKey: ghost)
                floatingOverrides.remove(ghost)
                savedFrames.removeValue(forKey: ghost)
                lastFrames.removeValue(forKey: ghost)
                missingScanCounts.removeValue(forKey: ghost)
                windowFirstTrackedAt.removeValue(forKey: ghost)
                windowsByID.removeValue(forKey: ghost)
            }
            // Do not call purgeStaleBundleTokens — it would wipe the other live siblings.
            _ = keeper
            affected.insert(wsID)
        }
        return affected
    }

    func dedupeBundleTilesInColumns() -> Set<String> {
        var structurallyChanged: Set<String> = []
        let liveAX = Set(ax.currentWindows.map(\.id))
        for (wsID, var ws) in workspaces.workspaces {
            var wsChanged = false
            let colCountBefore = ws.columns.count
            for colIdx in ws.columns.indices {
                var grouped: [String: [WindowID]] = [:]
                for id in ws.columns[colIdx].windows {
                    guard let win = windowsByID[id], let bid = win.bundleID, !bid.isEmpty else { continue }
                    grouped["\(bid)|\(id.pid)", default: []].append(id)
                }
                var drop = Set<WindowID>()
                for (key, ids) in grouped where ids.count > 1 {
                    let bid = String(key.split(separator: "|", maxSplits: 1)[0])
                    let liveIds = ids.filter { isLiveBundleSibling($0, liveAX: liveAX) }
                    let ghosts = ids.filter { !liveIds.contains($0) }
                    guard !ghosts.isEmpty else { continue } // all live → keep every window
                    // Prefer keeping live tiles; drop only ghosts.
                    for ghost in ghosts {
                        drop.insert(ghost)
                        workspaces.removeWindowEverywhere(ghost)
                        windowWorkspace.removeValue(forKey: ghost)
                        runtimeState.setAssignment(nil, for: ghost)
                        forcedTiledUntil.removeValue(forKey: ghost)
                        floatingOverrides.remove(ghost)
                        savedFrames.removeValue(forKey: ghost)
                        lastFrames.removeValue(forKey: ghost)
                        missingScanCounts.removeValue(forKey: ghost)
                        windowFirstTrackedAt.removeValue(forKey: ghost)
                        windowsByID.removeValue(forKey: ghost)
                    }
                    _ = bid
                }
                if !drop.isEmpty {
                    let newWindows = ws.columns[colIdx].windows.filter { !drop.contains($0) }
                    if newWindows != ws.columns[colIdx].windows {
                        ws.columns[colIdx].windows = newWindows
                        wsChanged = true
                    }
                }
            }
            ws.columns.removeAll { $0.windows.isEmpty }
            if wsChanged {
                if ws.focusedColumn >= ws.columns.count {
                    ws.focusedColumn = max(0, ws.columns.count - 1)
                }
                syncColumnWidthsToUsable(workspace: &ws, workspaceID: wsID)
                workspaces.setWorkspace(ws)
                if ws.columns.count != colCountBefore {
                    structurallyChanged.insert(wsID)
                }
            }
        }
        return structurallyChanged
    }

    func collapseDuplicateBundleColumns() -> Set<String> {
        var structurallyChanged: Set<String> = []
        let liveAX = Set(ax.currentWindows.map(\.id))
        for (wsID, var ws) in workspaces.workspaces {
            let colCountBefore = ws.columns.count
            var keyToCols: [String: [Int]] = [:]
            for (idx, col) in ws.columns.enumerated() {
                let keys = Set(col.windows.compactMap { id -> String? in
                    guard let win = windowsByID[id], let bid = win.bundleID, !bid.isEmpty else { return nil }
                    return "\(bid)|\(id.pid)"
                })
                if keys.count == 1, let key = keys.first {
                    keyToCols[key, default: []].append(idx)
                }
            }
            var removeCols: Set<Int> = []
            for (key, colIndices) in keyToCols where colIndices.count > 1 {
                let bid = String(key.split(separator: "|", maxSplits: 1)[0])
                let allIds = colIndices.flatMap { ws.columns[$0].windows }
                let liveIds = allIds.filter {
                    liveAX.contains($0) && windowsByID[$0] != nil && missingScanCounts[$0] == nil
                }
                guard liveIds.count <= 1,
                      let keeper = preferredBundleInstanceToken(among: allIds, bundleID: bid) else { continue }
                let keepCol = colIndices.first(where: { ws.columns[$0].windows.contains(keeper) }) ?? colIndices[0]
                for idx in colIndices where idx != keepCol {
                    removeCols.insert(idx)
                    for stale in ws.columns[idx].windows where stale != keeper {
                        purgeStaleBundleTokens(keeping: keeper, bundleID: bid, workspaceScope: wsID)
                    }
                }
                ws.columns[keepCol].windows = [keeper]
            }
            if !removeCols.isEmpty {
                ws.columns = ws.columns.enumerated().compactMap { removeCols.contains($0.0) ? nil : $0.1 }
                if ws.focusedColumn >= ws.columns.count {
                    ws.focusedColumn = max(0, ws.columns.count - 1)
                }
                syncColumnWidthsToUsable(workspace: &ws, workspaceID: wsID)
                workspaces.setWorkspace(ws)
                if ws.columns.count != colCountBefore {
                    structurallyChanged.insert(wsID)
                }
            }
        }
        return structurallyChanged
    }

    func healBundleTokenChurn() -> Set<String> {
        var changed = dedupeBundleInstanceTokens()
        changed.formUnion(dedupeBundleTilesInColumns())
        changed.formUnion(collapseDuplicateBundleColumns())
        return changed
    }

    func removePersistedWindowRefs(_ ref: RuntimeStateStore.WindowRef, fromWorkspace wsID: String) {
        guard var layout = runtimeState.workspaceLayout(for: wsID) else { return }
        let allowBundleWipe = ref.bundleID.map { isSingleBundleInstance($0) } ?? false
        var changed = false
        layout.columns = layout.columns.compactMap { col in
            var copy = col
            let before = copy.windows.count
            copy.windows.removeAll { saved in
                if saved.token == ref.token { return true }
                // Only wipe by bundle when this app truly has one window — otherwise
                // moving Safari A would erase Safari B's saved slot on the source WS.
                if allowBundleWipe, let bid = ref.bundleID, !bid.isEmpty, saved.bundleID == bid {
                    return true
                }
                return false
            }
            if copy.windows.count != before { changed = true }
            return copy.windows.isEmpty ? nil : copy
        }
        let floatBefore = layout.floating.count
        layout.floating.removeAll { saved in
            if saved.token == ref.token { return true }
            if allowBundleWipe, let bid = ref.bundleID, saved.bundleID == bid { return true }
            return false
        }
        if layout.floating.count != floatBefore { changed = true }
        if changed {
            runtimeState.setWorkspaceLayout(layout, for: wsID)
        }
    }

    func moveWindow(requestedID: WindowID, to workspaceID: String, follow: Bool = false) {
        guard workspaces.workspaces[workspaceID] != nil else { return }
        let fromHint = windowWorkspace[requestedID]
            ?? runtimeState.assignment(for: requestedID)
            ?? workspaces.workspaceID(containing: requestedID)
        logMove("move begin req=\(requestedID.token) → ws=\(workspaceID)")
        if let fromHint, fromHint != workspaceID {
            logMove("move send window to ws=\(workspaceID) (atalho ⌥⇧N — não é reorganizar coluna)")
        }

        guard let id = resolveLiveWindowID(for: requestedID, preferredWS: fromHint) else {
            logMove("move abort req=\(requestedID.token) — janela ausente (token stale?)")
            return
        }
        if id != requestedID {
            logMove("move resolve \(requestedID.token) → live \(id.token)")
        }

        if windowsByID[id] == nil {
            ax.scanAll()
            ingest(windows: ax.currentWindows)
        }
        guard var win = windowsByID[id], !win.isIgnored else {
            logMove("move abort live=\(id.token) — ignorada/ausente")
            return
        }

        if let last = lastMoveDedupe,
           last.0 == id, last.1 == workspaceID,
           Date().timeIntervalSince(last.2) < 0.75 {
            logMove("move dedupe skip live=\(id.token) → ws=\(workspaceID)")
            return
        }

        if !follow,
           authoritativeHome(for: id) == workspaceID,
           let ws = workspaces.workspaces[workspaceID],
           let loc = engine.locate(id, in: ws) {
            logMove("move noop live=\(id.token) already ws=\(workspaceID) slot=\(loc.col):\(loc.row)")
            if isHomeActiveOnAnyMonitor(workspaceID) {
                applyForcedTileFrame(for: id)
                focusWindow(id, raise: true)
            }
            return
        }

        if !follow,
           authoritativeHome(for: id) == workspaceID,
           workspaces.workspaces[workspaceID] != nil,
           engine.locate(id, in: workspaces.workspaces[workspaceID]!) == nil {
            let monitor = workspaces.preferredMonitor(forWorkspace: workspaceID, monitors: monitors.monitors)
                ?? monitors.monitorContaining(pointX: win.frame.midX, pointY: win.frame.midY)
                ?? primaryMonitor()
            guard let monitor else { return }
            suppressIngestReassignUntil = Date().addingTimeInterval(2.0)
            assignWindow(id, to: workspaceID, on: monitor, forceInsert: true, asNewColumn: false)
            healStaleColumnEntries()
            persistRuntimeState(forceWorkspaceLayouts: [workspaceID])
            if isHomeActiveOnAnyMonitor(workspaceID) {
                applyWorkspaceTileLayout(workspaceID, on: monitor, forceReveal: true, movedID: id)
                focusWindow(id, raise: true)
            }
            logMove("move reinsert live=\(id.token) → ws=\(workspaceID) (was orphan on home)")
            refreshChrome()
            return
        }

        lastMoveDedupe = (id, workspaceID, Date())

        let ref = RuntimeStateStore.WindowRef(window: win)
        let fromHome = fromHint
            ?? windowWorkspace[id]
            ?? runtimeState.assignment(for: id)
            ?? workspaces.workspaceID(containing: id)
        let crossWorkspace = fromHome != nil && fromHome != workspaceID

        if id != requestedID {
            windowWorkspace.removeValue(forKey: requestedID)
            runtimeState.setAssignment(nil, for: requestedID)
            workspaces.removeWindowEverywhere(requestedID)
        }
        if let bid = win.bundleID, !bid.isEmpty {
            ejectStaleBundleInstance(from: workspaceID, keeping: id)
        }
        if crossWorkspace, let fromHome {
            removePersistedWindowRefs(ref, fromWorkspace: fromHome)
        }

        // Explicit send forces tiling into that workspace (even if currently floating).
        floatingOverrides.remove(id)
        win.isFloating = false
        win.isScratchpad = false
        windowsByID[id] = win

        let monitor = workspaces.preferredMonitor(forWorkspace: workspaceID, monitors: monitors.monitors)
            ?? monitors.monitorContaining(pointX: win.frame.midX, pointY: win.frame.midY)
            ?? primaryMonitor()
        guard let monitor else { return }

        // Sticky home first — ingest must not re-float while we insert.
        applyStickyHomeForMove(workspaceID, win: win, live: id)
        suppressIngestReassignUntil = Date().addingTimeInterval(4.0)
        suppressWorkspaceFollowUntil = Date().addingTimeInterval(1.0)

        var forcePersist: Set<String> = [workspaceID]
        if crossWorkspace, let fromHome, fromHome != workspaceID {
            scheduleRebalanceWorkspace(fromHome, force: true)
            forcePersist.insert(fromHome)
        }

        let rules = configStore.config.rules
        if AppRules.forcesFloat(rules: rules, window: win) {
            var floating = win
            floating.isFloating = true
            windowsByID[id] = floating
            workspaces.removeWindowEverywhere(id)
            savedFrames.removeValue(forKey: id)
            lastFrames.removeValue(forKey: id)
            missingScanCounts.removeValue(forKey: id)
            ensureFloatHome(id, win: floating)
            markFloatRevealProtected(id)
            windowFirstTrackedAt[id] = Date()
            suppressGeometryEnforce(for: 0.75)
            healStaleColumnEntries()
            persistRuntimeState(forceWorkspaceLayouts: forcePersist)
            logMove("move float live=\(id.token) → ws=\(workspaceID) sticky=\(windowWorkspace[id] ?? "?")")
            if isHomeActiveOnAnyMonitor(workspaceID) {
                revealActiveFloats(ids: [id])
                focusWindow(id, raise: true)
            }
            refreshChrome()
            return
        }

        // Explicit send forces tiling into that workspace (even if currently floating).
        floatingOverrides.remove(id)
        win.isFloating = false
        win.isScratchpad = false
        windowsByID[id] = win

        forcedTiledUntil[id] = Date().addingTimeInterval(8.0)

        if var tracked = windowsByID[id] {
            if let frame = ax.currentFrame(of: id) { tracked.frame = frame }
            tracked.isFloating = false
            tracked.isScratchpad = false
            windowsByID[id] = tracked
        }

        workspaces.removeWindowEverywhere(id)
        savedFrames.removeValue(forKey: id)
        lastFrames.removeValue(forKey: id)
        missingScanCounts.removeValue(forKey: id)
        ax.setMinimized(false, id: id)

        assignWindow(
            id,
            to: workspaceID,
            on: monitor,
            forceInsert: true,
            asNewColumn: crossWorkspace
        )

        if var ws = workspaces.workspaces[workspaceID] {
            let usable = engine.usableArea(monitor: monitor.layoutFrame)
            if crossWorkspace {
                engine.fitAllColumnsOnScreen(workspace: &ws, usable: usable, equalSplit: true)
                let widths = ws.columns.map { Int($0.width) }.map(String.init).joined(separator: "+")
                logMove("move fit ws=\(workspaceID) cols=\(ws.columns.count) widths=\(widths)")
            }
            if let loc = engine.locate(id, in: ws) {
                ws.focusedColumn = loc.col
                ws.focusedWindowInColumn[loc.col] = loc.row
            }
            workspaces.setWorkspace(ws)
        }

        windowFirstTrackedAt[id] = Date()
        suppressGeometryEnforce(for: 0.75)
        healStaleColumnEntries()
        // Cross-workspace moves must rewrite source layout even while the window is still live
        // (old shrink guard left Safari on WS1 forever). Force destructive flush for both sides.
        let wasDestructive = allowDestructiveLayoutFlush
        allowDestructiveLayoutFlush = true
        persistRuntimeState(forceWorkspaceLayouts: forcePersist)
        allowDestructiveLayoutFlush = wasDestructive
        let layoutHas = forcePersist.sorted().map { ws -> String in
            let present = workspaces.workspaces[ws]?.columns.flatMap(\.windows).contains(id) == true
            return "\(ws):\(present ? "yes" : "no")"
        }.joined(separator: ",")
        logMove(
            "move persist ws=\(forcePersist.sorted().joined(separator: ",")) sticky=\(windowWorkspace[id] ?? "?") layoutHas=\(layoutHas)"
        )
        let slot: String = {
            guard let ws = workspaces.workspaces[workspaceID],
                  let loc = engine.locate(id, in: ws) else { return "orphan" }
            return "\(loc.col):\(loc.row)"
        }()
        logMove(
            "move done live=\(id.token) from=\(fromHome ?? "?") → ws=\(workspaceID) cross=\(crossWorkspace) slot=\(slot) sticky=\(windowWorkspace[id] ?? "?")"
        )

        if crossWorkspace, let ws = workspaces.workspaces[workspaceID] {
            for col in ws.columns {
                for wid in col.windows {
                    lastFrames.removeValue(forKey: wid)
                }
            }
        }

        let targetActive = isHomeActiveOnAnyMonitor(workspaceID)
        let applyLayout = { [weak self] in
            guard let self else { return }
            self.applyWorkspaceTileLayout(workspaceID, on: monitor, forceReveal: true, movedID: id)
            self.applyForcedTileFrame(for: id)
            self.scheduleTileFrameEnforcement()
            self.focusWindow(id, raise: true)
        }
        if follow {
            switchWorkspace(id: workspaceID, on: monitor.id)
            applyLayout()
        } else if targetActive {
            applyLayout()
            for delay in [0.15, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    guard self.authoritativeHome(for: id) == workspaceID else { return }
                    self.applyWorkspaceTileLayout(workspaceID, on: monitor, forceReveal: true, movedID: id)
                }
            }
        } else {
            animator.stop()
            applyWorkspaceVisibility(animated: false)
        }
        refreshChrome()
    }

    func primaryMonitor() -> MonitorInfo? {
        monitors.monitors.first(where: { $0.id == primaryMonitorID }) ?? monitors.monitors.first
    }

    func monitorForWorkspaceCycle() -> MonitorInfo {
        let loc = NSEvent.mouseLocation
        let mainHeight = Double(NSScreen.screens.first?.frame.height ?? loc.y)
        let axX = Double(loc.x)
        let axY = mainHeight - Double(loc.y)
        if let under = monitors.monitorContaining(pointX: axX, pointY: axY) {
            primaryMonitorID = under.id
            return under
        }
        return monitorForAction() ?? primaryMonitor() ?? monitors.monitors[0]
    }

    func actionTargetWindowID() -> WindowID? {
        let activeHomes = Set(workspaces.activeWorkspaceByMonitor.values)
        func isActionable(_ id: WindowID) -> Bool {
            windowsByID[id] != nil || workspaces.workspaceID(containing: id) != nil
        }
        func prefersActiveWorkspace(_ id: WindowID) -> Bool {
            if let home = workspaceHome(for: id), activeHomes.contains(home) { return true }
            if let colHome = workspaces.workspaceID(containing: id), activeHomes.contains(colHome) {
                return true
            }
            return false
        }

        if let axID = axFocusedWindowID ?? ax.frontmostFocusedWindowID(), isActionable(axID) {
            if prefersActiveWorkspace(axID) { return axID }
            if let win = windowsByID[axID], let bid = win.bundleID, !bid.isEmpty {
                let candidates = windowsByID.values.filter { candidate in
                    guard !candidate.isIgnored else { return false }
                    guard candidate.bundleID == bid, candidate.id.pid == axID.pid else { return false }
                    return prefersActiveWorkspace(candidate.id)
                        && workspaces.workspaceID(containing: candidate.id) != nil
                }
                if let best = candidates.max(by: {
                    bundleInstanceScore($0.id) < bundleInstanceScore($1.id)
                }) {
                    return best.id
                }
            }
            return axID
        }
        return focusedWindowID()
    }

    func monitorForTileAction() -> MonitorInfo? {
        let underMouse = monitorForWorkspaceCycle()
        if let activeWS = workspaces.activeWorkspaceByMonitor[underMouse.id],
           workspaces.workspaces[activeWS] != nil,
           actionTargetTileWindow(on: underMouse) != nil {
            primaryMonitorID = underMouse.id
            return underMouse
        }
        if let axID = axFocusedWindowID ?? ax.frontmostFocusedWindowID(),
           let home = authoritativeHome(for: axID) ?? workspaces.workspaceID(containing: axID) {
            let mon = displayMonitor(forHome: home, fallback: underMouse)
            if actionTargetTileWindow(on: mon) != nil {
                primaryMonitorID = mon.id
                return mon
            }
        }
        for mon in monitors.monitors {
            if actionTargetTileWindow(on: mon) != nil {
                primaryMonitorID = mon.id
                return mon
            }
        }
        return nil
    }

    func actionTargetTileWindow(on monitor: MonitorInfo) -> WindowID? {
        guard let activeWS = workspaces.activeWorkspaceByMonitor[monitor.id],
              let ws = workspaces.workspaces[activeWS] else {
            return actionTargetWindowID()
        }
        let columnIDs = Set(ws.columns.flatMap(\.windows))

        if let axID = axFocusedWindowID ?? ax.frontmostFocusedWindowID(),
           columnIDs.contains(axID),
           windowsByID[axID]?.isTiled == true {
            return axID
        }
        if let fid = ws.focusedWindowID, columnIDs.contains(fid),
           windowsByID[fid]?.isTiled == true {
            return fid
        }
        return ws.columns.lazy.flatMap(\.windows).first { id in
            windowsByID[id]?.isTiled == true
        }
    }

    func syncColumnFocus(to id: WindowID) {
        guard let home = authoritativeHome(for: id) ?? workspaces.workspaceID(containing: id),
              var ws = workspaces.workspaces[home],
              let loc = engine.locate(id, in: ws)
        else { return }
        ws.focusedColumn = loc.col
        ws.focusedWindowInColumn[loc.col] = loc.row
        workspaces.setWorkspace(ws)
    }

    func actionWorkspaceID(for monitor: MonitorInfo) -> String? {
        if let id = actionTargetWindowID() {
            if let home = authoritativeHome(for: id) ?? workspaces.workspaceID(containing: id) {
                return home
            }
        }
        return workspaces.activeWorkspaceByMonitor[monitor.id]
    }

    func mutateWorkspaceForAction(
        on monitor: MonitorInfo,
        scopeToActiveWorkspace: Bool = false,
        _ body: (inout WorkspaceState) -> Void
    ) {
        let targetID = scopeToActiveWorkspace
            ? actionTargetTileWindow(on: monitor)
            : actionTargetWindowID()
        let home: String? = {
            if scopeToActiveWorkspace,
               let activeWS = workspaces.activeWorkspaceByMonitor[monitor.id] {
                return activeWS
            }
            if let id = targetID {
                return authoritativeHome(for: id) ?? workspaces.workspaceID(containing: id)
            }
            return nil
        }()
        if let id = targetID,
           let home,
           var ws = workspaces.workspaces[home] {
            // Structural tile ops require the window to live in columns — reinsert orphans
            // into *home*, never mutateActive (that moved the wrong column after Quake/float).
            if windowsByID[id]?.isTiled == true, engine.locate(id, in: ws) == nil {
                reinsertOrphanTiles()
                guard var healed = workspaces.workspaces[home],
                      engine.locate(id, in: healed) != nil
                else { return }
                body(&healed)
                workspaces.setWorkspace(healed)
                return
            }
            body(&ws)
            workspaces.setWorkspace(ws)
            return
        }
        mutateActive(monitor.id, body)
    }

    func monitorForAction() -> MonitorInfo? {
        if let id = actionTargetWindowID() {
            let home = authoritativeHome(for: id)
            if let home,
               let mon = monitors.monitors.first(where: { workspaces.activeWorkspaceByMonitor[$0.id] == home }) {
                primaryMonitorID = mon.id
                return mon
            }
            if let home,
               let preferred = workspaces.preferredMonitor(forWorkspace: home, monitors: monitors.monitors) {
                primaryMonitorID = preferred.id
                return preferred
            }
            let frame = ax.currentFrame(of: id) ?? lastFrames[id] ?? windowsByID[id]?.frame
            if let frame,
               let mon = monitors.monitorContaining(pointX: frame.midX, pointY: frame.midY) {
                primaryMonitorID = mon.id
                return mon
            }
        }
        return primaryMonitor()
    }

    func layoutScopeMonitor(for windowID: WindowID? = nil) -> MonitorInfo? {
        if let windowID {
            if let home = authoritativeHome(for: windowID) {
                if let mon = monitors.monitors.first(where: { workspaces.activeWorkspaceByMonitor[$0.id] == home }) {
                    return mon
                }
                if let preferred = workspaces.preferredMonitor(forWorkspace: home, monitors: monitors.monitors) {
                    return preferred
                }
            }
            if let frame = ax.currentFrame(of: windowID) ?? lastFrames[windowID] ?? windowsByID[windowID]?.frame,
               let mon = monitors.monitorContaining(pointX: frame.midX, pointY: frame.midY) {
                return mon
            }
        }
        return monitorForAction() ?? primaryMonitor()
    }

    func focusedWindowID() -> WindowID? {
        guard let mon = primaryMonitor() else { return nil }
        return workspaces.activeWorkspace(for: mon.id)?.focusedWindowID
    }

    func mutateActive(_ monitorID: CGDirectDisplayID, _ body: (inout WorkspaceState) -> Void) {
        workspaces.updateActiveWorkspace(for: monitorID, body)
    }

    func focusWindow(_ id: WindowID, raise: Bool = true) {
        if chromeBlocksFocusFollowsMouse() { return }
        // Dismissed Quake must stay parked — raising it undoes hide and looks like a reopen.
        if (id == quake.windowID || isQuakeOwned(id)), !quake.isVisible {
            return
        }
        axFocusedWindowID = id
        var needsLayout = false
        for mon in monitors.monitors {
            workspaces.updateActiveWorkspace(for: mon.id) { ws in
                if let loc = engine.locate(id, in: ws) {
                    let colChanged = ws.focusedColumn != loc.col
                    let rowChanged = (ws.focusedWindowInColumn[loc.col] ?? 0) != loc.row
                    ws.focusedColumn = loc.col
                    ws.focusedWindowInColumn[loc.col] = loc.row
                    if colChanged || rowChanged {
                        needsLayout = true
                        // Never snap the strip while the user is panning columns — that
                        // fights continuous trackpad scroll and feels stuck on the prior tile.
                        if ws.layout == .niri, !isColumnPanActive {
                            let usable = engine.usableArea(monitor: mon.layoutFrame)
                            engine.snapViewToFocusedColumn(&ws, usable: usable)
                        }
                    }
                }
            }
        }
        if raise {
            if focusSourceIsMouse {
                suppressGeometryEnforce(for: 0.45)
            }
            if let win = windowsByID[id], win.isFloating || win.isScratchpad || floatingOverrides.contains(id) {
                markFloatRevealProtected(id)
            }
            revealBeforeFocus(id)
            ax.focus(id)
            maybeWarpCursor(to: id)
        }
        // Click / focus-follows-mouse used to skip relayout — niri tabbing and
        // off-viewport columns then drifted until the next workspace switch.
        // Do NOT re-force stack frames on every focus: WhatsApp/Discord (Electron)
        // emit AX Resized when raised, which re-entered geometry enforce and made
        // sibling heights pump forever.
        if needsLayout {
            suppressGeometryEnforce(for: 0.55)
            relayout(animated: false)
            healUnusableFocusedFrame(id)
        } else if let win = windowsByID[id], win.isFloating || win.isScratchpad || floatingOverrides.contains(id) {
            refreshBorder()
            refreshStatusItem()
        } else {
            healUnusableFocusedFrame(id)
            refreshBorder()
            refreshStatusItem()
        }
    }

    func revealBeforeFocus(_ id: WindowID) {
        guard let win = windowsByID[id], !win.isIgnored else { return }
        if id == quake.windowID || isQuakeOwned(id) { return }
        let monitors = monitors.monitors.map(\.frame)
        let live = ax.currentFrame(of: id)
        let unusable = ax.isMinimized(id)
            || live.map { !OffscreenParking.isUsableOnscreenFrame($0, monitors: monitors) } ?? true
        guard unusable else { return }
        let frame: Rect?
        if win.isFloating || win.isScratchpad || floatingOverrides.contains(id) {
            if let home = authoritativeHome(for: id), isHomeActiveOnAnyMonitor(home),
               let layoutMonitor = primaryMonitor() {
                let liveNow = ax.currentFrame(of: id) ?? win.frame
                frame = floatFrameForActiveHome(
                    id: id, home: home, live: liveNow, layoutMonitor: layoutMonitor
                )
            } else {
                frame = savedFrames[id].flatMap({
                    OffscreenParking.isUsableOnscreenFrame($0, monitors: monitors) ? $0 : nil
                }) ?? lastFrames[id].flatMap({
                    OffscreenParking.isUsableOnscreenFrame($0, monitors: monitors) ? $0 : nil
                })
            }
        } else {
            frame = expectedTileFrame(for: id)
                ?? savedFrames[id].flatMap({ OffscreenParking.isUsableOnscreenFrame($0, monitors: monitors) ? $0 : nil })
                ?? lastFrames[id].flatMap({
                    // Prefer lastFrames only when they look like a real tile, not a park strip.
                    OffscreenParking.isUsableOnscreenFrame($0, monitors: monitors) ? $0 : nil
                })
        }
        guard let frame else { return }
        ax.reveal(frame: frame, id: id)
        lastFrames[id] = frame
    }

    func healUnusableFocusedFrame(_ id: WindowID) {
        if overlaysCaptureFocus { return }
        guard let win = windowsByID[id], win.isTiled, !win.isIgnored else { return }
        let monitors = monitors.monitors.map(\.frame)
        guard let live = ax.currentFrame(of: id),
              !OffscreenParking.isUsableOnscreenFrame(live, monitors: monitors)
        else { return }
        if let frame = expectedTileFrame(for: id) ?? lastFrames[id] {
            ax.reveal(frame: frame, id: id)
            lastFrames[id] = frame
        }
    }

    func expectedTileFrame(for id: WindowID) -> Rect? {
        guard let win = windowsByID[id], win.isTiled else { return nil }
        let home = authoritativeHome(for: id) ?? workspaces.workspaceID(containing: id)
        guard let home, var ws = workspaces.workspaces[home] else { return nil }
        let mon = monitors.monitors.first(where: {
            workspaces.activeWorkspaceByMonitor[$0.id] == home
        }) ?? workspaces.preferredMonitor(forWorkspace: home, monitors: monitors.monitors)
            ?? primaryMonitor()
        guard let mon else { return nil }
        // Ensure column focus points at this window so tabbing fills the right tile.
        if let loc = engine.locate(id, in: ws) {
            ws.focusedColumn = loc.col
            ws.focusedWindowInColumn[loc.col] = loc.row
        }
        return engine.computeFrames(
            workspace: ws,
            windows: windowsByID,
            monitor: mon.layoutFrame,
            active: true,
            stackExcluded: stackExcludedFromLayout().subtracting([id]),
            layoutExcluded: layoutExcludedWindowIDs(for: home)
        ).first(where: { $0.windowID == id && $0.visible })?.frame
    }

    func focusFloatingWindow(on monitorID: CGDirectDisplayID) {
        let tiledIDs: Set<WindowID> = Set(
            workspaces.workspaces.values.flatMap { ws in ws.columns.flatMap(\.windows) }
        )
        let activeID = workspaces.activeWorkspaceByMonitor[monitorID]
        let live = Set(ax.currentWindows.map(\.id))
        let candidates = windowsByID.values.filter { win in
            guard !win.isIgnored else { return false }
            guard live.contains(win.id) else { return false }
            guard missingScanCounts[win.id] == nil else { return false }
            let loose = win.isFloating || win.isScratchpad || !tiledIDs.contains(win.id)
            guard loose else { return false }
            if let activeID {
                return windowWorkspace[win.id] == activeID
            }
            let host = monitors.monitorContaining(pointX: win.frame.midX, pointY: win.frame.midY)
            return host?.id == monitorID
        }
        // Prefer currently focused float on this monitor; else first by app name.
        let ordered = candidates.sorted {
            $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
        let target = ordered.first(where: { $0.id == axFocusedWindowID })
            ?? ordered.first
        guard let target else {
            // Dead float icons (closed Finder, etc.) — drop ghosts and refresh the bar.
            pruneDeadTrackedWindows()
            refreshChrome()
            return
        }
        markFloatRevealProtected(target.id)
        focusSourceIsMouse = false
        focusWindow(target.id)
        refreshChrome()
    }

    func pruneDeadTrackedWindows() {
        let live = Set(ax.currentWindows.map(\.id))
        let dead = windowsByID.keys.filter { !live.contains($0) && $0 != quake.windowID }
        guard !dead.isEmpty else { return }
        var strippedLayouts: Set<String> = []
        for id in dead {
            if let home = workspaces.workspaceID(containing: id) ?? windowWorkspace[id] {
                strippedLayouts.insert(home)
            }
            workspaces.removeWindowEverywhere(id)
            windowsByID.removeValue(forKey: id)
            windowWorkspace.removeValue(forKey: id)
            floatingOverrides.remove(id)
            savedFrames.removeValue(forKey: id)
            lastFrames.removeValue(forKey: id)
            missingScanCounts.removeValue(forKey: id)
            runtimeState.setAssignment(nil, for: id)
        }
        for wsID in strippedLayouts {
            scheduleRebalanceWorkspace(wsID, force: true)
        }
        persistRuntimeState(forceWorkspaceLayouts: strippedLayouts)
        if !strippedLayouts.isEmpty {
            scheduleVisibilityRefresh(animated: false, delay: 0)
        }
    }

    func handleUserClosedWindow(_ id: WindowID) {
        if id == quake.windowID || isQuakeOwned(id) {
            // Ghostty/Terminal often emit AX destroy noise when opening tabs (⌘T).
            // Confirm the window is actually gone before tearing Quake down.
            scheduleConfirmQuakeClosed(suspectID: id)
            return
        }
        guard windowsByID[id] != nil || workspaces.workspaceID(containing: id) != nil else { return }
        let pid = id.pid
        let bundleID = windowsByID[id]?.bundleID
        let home = windowWorkspace[id] ?? workspaces.workspaceID(containing: id)
        let homeWasActive = home.map { isHomeActiveOnAnyMonitor($0) } ?? false
        let wasInColumns = workspaces.workspaceID(containing: id) != nil

        logMove("close ax-destroy win=\(id.token) bundle=\(bundleID ?? "?") home=\(home ?? "-")")

        workspaces.removeWindowEverywhere(id)
        windowsByID.removeValue(forKey: id)
        windowWorkspace.removeValue(forKey: id)
        floatingOverrides.remove(id)
        savedFrames.removeValue(forKey: id)
        lastFrames.removeValue(forKey: id)
        runtimeState.setAssignment(nil, for: id)
        windowFirstTrackedAt.removeValue(forKey: id)
        forcedTiledUntil.removeValue(forKey: id)
        missingScanCounts.removeValue(forKey: id)
        appRuleFramesApplied.remove(id)

        if let home, wasInColumns {
            pruneVacantColumnSlots(wsID: home)
            if isHomeActiveOnAnyMonitor(home) {
                snapWorkspaceTilesAfterColumnChange(home)
            } else {
                rebalanceWorkspaceAfterWindowLeft(home, force: true)
            }
        }
        persistRuntimeState()
        refreshChrome()

        if homeWasActive || wasInColumns {
            scheduleQuitIfLastLayoutWindowClosed(pid: pid, bundleID: bundleID, homeWasActive: true)
        }
    }

}
