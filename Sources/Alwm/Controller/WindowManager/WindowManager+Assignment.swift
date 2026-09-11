import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC
import AlwmPluginAPI

// MARK: - Window assignment — ingest homes, float/tile placement

extension WindowManager {
    func resolveTargetWorkspace(for win: ManagedWindow, on monitor: MonitorInfo) -> String? {
        let rules = configStore.config.rules
        if let preferred = AppRules.preferredWorkspace(rules: rules, window: win),
           workspaces.workspaces[preferred] != nil {
            return preferred
        }
        if let sticky = windowWorkspace[win.id] ?? runtimeState.assignment(for: win.id),
           workspaces.workspaces[sticky] != nil {
            return sticky
        }
        if let home = savedHome(for: win, id: win.id) {
            return home
        }
        if isBootstrapping || isInPostLaunchLayoutGrace() {
            // Never dump orphans into the active workspace while restore / AX recovery is still pending.
            return nil
        }
        let idx = workspaces.monitorIndex(of: monitor.id, in: monitors.monitors) ?? 0
        let pool = workspaces.definitionsVisible(onMonitorIndex: idx).map(\.id)
        if let active = workspaces.activeWorkspaceByMonitor[monitor.id],
           pool.contains(active) {
            return active
        }
        return pool.first(where: { workspaces.workspaces[$0] != nil }) ?? firstWorkspaceID()
    }

    func bootstrapDefaultWorkspace(on monitor: MonitorInfo) -> String? {
        firstWorkspaceID()
    }

    func assignWindow(
        _ id: WindowID,
        to workspaceID: String,
        on monitor: MonitorInfo,
        forceInsert: Bool = false,
        asNewColumn: Bool = false
    ) {
        // Quake scratchpad is sticky-float only — never insert into columns.
        if isQuakeOwned(id) {
            floatingOverrides.insert(id)
            if var win = windowsByID[id] {
                win.isFloating = true
                win.isScratchpad = true
                windowsByID[id] = win
            }
            workspaces.removeWindowEverywhere(id)
            ensureFloatHome(id, win: windowsByID[id] ?? ManagedWindow(
                id: id, title: "", bundleID: nil, appName: "", frame: .init(x: 0, y: 0, width: 1, height: 1)
            ))
            return
        }
        if let win = windowsByID[id],
           AppRules.forcesFloat(rules: configStore.config.rules, window: win) {
            var floating = win
            floating.isFloating = true
            windowsByID[id] = floating
            forcedTiledUntil.removeValue(forKey: id)
            workspaces.removeWindowEverywhere(id)
            windowWorkspace[id] = workspaceID
            runtimeState.setAssignment(workspaceID, for: id)
            ensureFloatHome(id, win: floating)
            return
        }
        // Fresh emoji/sticker/sheet popups must never become columns (WhatsApp equal-split).
        // Only gate *new* windows — sticky tiles can briefly report a small AX frame.
        let usable = engine.usableArea(monitor: monitor.layoutFrame)
        let isFreshWindow = Date().timeIntervalSince(windowFirstTrackedAt[id] ?? .distantPast) < 8
        if floatingOverrides.contains(id)
            || (isFreshWindow
                && windowsByID[id].map { !looksLikeMainTiledWindow($0.frame, usable: usable) } == true)
        {
            if var floating = windowsByID[id] {
                floating.isFloating = true
                windowsByID[id] = floating
                floatingOverrides.insert(id)
                forcedTiledUntil.removeValue(forKey: id)
                workspaces.removeWindowEverywhere(id)
                windowWorkspace[id] = workspaceID
                runtimeState.setAssignment(workspaceID, for: id)
                ensureFloatHome(id, win: floating)
            }
            return
        }
        ejectStaleBundleInstance(from: workspaceID, keeping: id)
        if forceInsert {
            workspaces.insert(id, into: workspaceID) { ws in
                if asNewColumn, !ws.columns.isEmpty {
                    engine.insertWindowAsNewColumn(id, into: &ws, usable: usable)
                } else {
                    engine.insertWindow(id, into: &ws, usable: usable)
                }
                engine.ensureColumnWidths(workspace: &ws, usable: usable)
            }
            windowWorkspace[id] = workspaceID
            runtimeState.setAssignment(workspaceID, for: id)
            return
        }
        // Already in the right columns — never re-insert (that appends and destroys order).
        if workspaces.workspaceID(containing: id) == workspaceID {
            windowWorkspace[id] = workspaceID
            runtimeState.setAssignment(workspaceID, for: id)
            return
        }
        if placeWindowFromSnapshot(id, into: workspaceID, usable: usable) {
            windowWorkspace[id] = workspaceID
            runtimeState.setAssignment(workspaceID, for: id)
            return
        }
        // Prefer the saved column slot even when the exact row failed — never dump into a
        // maximized foreign column (that parks Electron windows on top of the stack).
        if placeWindowInSavedColumn(id, into: workspaceID, usable: usable) {
            windowWorkspace[id] = workspaceID
            runtimeState.setAssignment(workspaceID, for: id)
            return
        }
        workspaces.insert(id, into: workspaceID) { ws in
            // Brand-new window: sit beside existing tiles. Stacking into a 3-high
            // column (Calendar into WhatsApp+Discord) undersizes frames and AX flicker-loops.
            // Same-bundle already live here (Safari AX siblings): new column without
            // equal-rebalance so WhatsApp/Discord widths don't jump every few seconds.
            if !ws.columns.isEmpty {
                engine.insertWindowAsNewColumn(id, into: &ws, usable: usable)
                let bid = windowsByID[id]?.bundleID
                let sameBundleLive = bid.map { bundle in
                    ws.columns.flatMap(\.windows).contains { wid in
                        wid != id
                            && windowsByID[wid]?.bundleID == bundle
                            && missingScanCounts[wid] == nil
                    }
                } ?? false
                if sameBundleLive {
                    engine.ensureColumnWidths(workspace: &ws, usable: usable)
                    engine.fitAllColumnsOnScreen(workspace: &ws, usable: usable)
                } else {
                    engine.niri.rebalanceColumnsEqually(workspace: &ws, usable: usable)
                }
            } else {
                engine.insertWindow(id, into: &ws, usable: usable)
            }
            engine.ensureColumnWidths(workspace: &ws, usable: usable)
        }
        windowWorkspace[id] = workspaceID
        runtimeState.setAssignment(workspaceID, for: id)
    }

    func placeWindowFromSnapshot(_ id: WindowID, into workspaceID: String, usable: Rect) -> Bool {
        guard var ws = workspaces.workspaces[workspaceID],
              let snap = runtimeState.snapshot.workspaceLayouts[workspaceID],
              let win = windowsByID[id],
              !AppRules.forcesFloat(rules: configStore.config.rules, window: win)
        else { return false }

        let refMatches: (RuntimeStateStore.WindowRef) -> Bool = { [self] ref in
            windowMatchesSavedRef(win, ref: ref)
        }

        var targetCol: Int?
        var targetRow: Int?
        for (c, colSnap) in snap.columns.enumerated() {
            if let r = colSnap.windows.firstIndex(where: refMatches) {
                // Prefer a free slot — multi-window apps claim distinct refs left-to-right.
                if refSlotTaken(ref: colSnap.windows[r], workspaceID: workspaceID, except: id) {
                    continue
                }
                targetCol = c
                targetRow = r
                break
            }
        }
        // Title churn: resolve which saved ref this live window fills (bundle order).
        if targetCol == nil {
            let liveByToken = Dictionary(uniqueKeysWithValues: windowsByID.keys.map { ($0.token, $0) })
            var claimed = Set(ws.columns.flatMap(\.windows))
            claimed.remove(id)
            for (c, colSnap) in snap.columns.enumerated() {
                for (r, ref) in colSnap.windows.enumerated() {
                    guard let resolved = resolveLiveWindow(
                        ref,
                        preferredWS: workspaceID,
                        liveByToken: liveByToken,
                        used: claimed
                    ), resolved == id else { continue }
                    targetCol = c
                    targetRow = r
                    break
                }
                if targetCol != nil { break }
            }
        }
        guard let targetCol, let targetRow else { return false }
        let isFresh = Date().timeIntervalSince(windowFirstTrackedAt[id] ?? .distantPast) < 8
        if isFresh, ws.columns.indices.contains(targetCol),
           !ws.columns[targetCol].windows.filter({ $0 != id }).isEmpty {
            // Don't pile a newly opened window onto an occupied snapshot column.
            return false
        }

        workspaces.removeWindowEverywhere(id)
        ws = workspaces.workspaces[workspaceID] ?? ws

        while ws.columns.count <= targetCol {
            ws.columns.append(Column(windows: [], width: 0))
        }
        let row = min(targetRow, ws.columns[targetCol].windows.count)
        ws.columns[targetCol].windows.insert(id, at: row)
        if targetCol < snap.columns.count {
            let colSnap = snap.columns[targetCol]
            if colSnap.width > 0 { ws.columns[targetCol].width = colSnap.width }
            ws.columns[targetCol].isMaximized = colSnap.isMaximized
            ws.columns[targetCol].restoreWidth = colSnap.restoreWidth
        }
        remapLeafWeight(for: id, from: snap, into: &ws)
        engine.ensureColumnWidths(workspace: &ws, usable: usable)
        workspaces.setWorkspace(ws)
        return true
    }

    func placeWindowInSavedColumn(_ id: WindowID, into workspaceID: String, usable: Rect) -> Bool {
        guard var ws = workspaces.workspaces[workspaceID],
              let snap = runtimeState.snapshot.workspaceLayouts[workspaceID],
              let win = windowsByID[id]
        else { return false }

        var targetCol: Int?
        for (c, colSnap) in snap.columns.enumerated() {
            if colSnap.windows.contains(where: { windowMatchesSavedRef(win, ref: $0) }) {
                targetCol = c
                break
            }
            // Bundle-only match is for restore after token churn — never for a *fresh*
            // window while a live same-bundle tile already occupies that column (Safari
            // AX siblings were stacking → half-height until leave/re-enter).
            if let bid = win.bundleID, !bid.isEmpty,
               colSnap.windows.contains(where: { $0.bundleID == bid }) {
                let isFresh = Date().timeIntervalSince(windowFirstTrackedAt[id] ?? .distantPast) < 8
                let liveSameInCol = ws.columns.indices.contains(c)
                    && ws.columns[c].windows.contains { wid in
                        wid != id
                            && windowsByID[wid]?.bundleID == bid
                            && missingScanCounts[wid] == nil
                    }
                if isFresh, liveSameInCol { continue }
                targetCol = c
                break
            }
        }
        guard let targetCol else { return false }
        let isFresh = Date().timeIntervalSince(windowFirstTrackedAt[id] ?? .distantPast) < 8
        if isFresh, ws.columns.indices.contains(targetCol),
           !ws.columns[targetCol].windows.filter({ $0 != id }).isEmpty {
            // Don't pile a newly opened window onto an occupied saved column.
            return false
        }

        workspaces.removeWindowEverywhere(id)
        ws = workspaces.workspaces[workspaceID] ?? ws
        while ws.columns.count <= targetCol {
            ws.columns.append(Column(windows: [], width: 0))
        }
        // Never append into a maximized column unless the snapshot says this window belongs there.
        if ws.columns[targetCol].isMaximized,
           targetCol < snap.columns.count,
           !snap.columns[targetCol].windows.contains(where: { windowMatchesSavedRef(win, ref: $0) }),
           let stackCol = snap.columns.enumerated().first(where: { !$0.element.isMaximized && !$0.element.windows.isEmpty })?.offset {
            while ws.columns.count <= stackCol {
                ws.columns.append(Column(windows: [], width: 0))
            }
            ws.columns[stackCol].windows.append(id)
            if snap.columns[stackCol].width > 0 {
                ws.columns[stackCol].width = snap.columns[stackCol].width
            }
            remapLeafWeight(for: id, from: snap, into: &ws)
            engine.ensureColumnWidths(workspace: &ws, usable: usable)
            workspaces.setWorkspace(ws)
            return true
        }

        ws.columns[targetCol].windows.append(id)
        if targetCol < snap.columns.count, snap.columns[targetCol].width > 0 {
            ws.columns[targetCol].width = snap.columns[targetCol].width
        }
        remapLeafWeight(for: id, from: snap, into: &ws)
        engine.ensureColumnWidths(workspace: &ws, usable: usable)
        workspaces.setWorkspace(ws)
        return true
    }

    func remappedLeafWeights(
        from snap: RuntimeStateStore.WorkspaceLayoutSnapshot,
        columns: [Column]
    ) -> [String: Double] {
        var mapped: [String: Double] = [:]
        var claimedRefs = Set<String>()
        let allRefs = snap.columns.flatMap(\.windows)
        for col in columns {
            for id in col.windows {
                guard let win = windowsByID[id] else { continue }
                if let direct = snap.leafWeights[id.token] {
                    mapped[id.token] = direct
                    claimedRefs.insert(id.token)
                    continue
                }
                if let ref = allRefs.first(where: {
                    !claimedRefs.contains($0.token) && windowMatchesSavedRef(win, ref: $0)
                }), let w = snap.leafWeights[ref.token] {
                    mapped[id.token] = w
                    claimedRefs.insert(ref.token)
                }
            }
        }
        return mapped
    }

    func remapLeafWeight(
        for id: WindowID,
        from snap: RuntimeStateStore.WorkspaceLayoutSnapshot,
        into ws: inout WorkspaceState
    ) {
        if let direct = snap.leafWeights[id.token] {
            ws.leafWeights[id.token] = direct
            return
        }
        guard let win = windowsByID[id] else { return }
        for ref in snap.columns.flatMap(\.windows) {
            guard windowMatchesSavedRef(win, ref: ref),
                  let w = snap.leafWeights[ref.token] else { continue }
            ws.leafWeights[id.token] = w
            return
        }
    }

    func ensureFloatHome(_ id: WindowID, win: ManagedWindow) {
        if let home = windowWorkspace[id], workspaces.workspaces[home] != nil { return }
        if let sticky = runtimeState.assignment(for: id),
           workspaces.workspaces[sticky] != nil {
            windowWorkspace[id] = sticky
            runtimeState.setAssignment(sticky, for: id)
            return
        }
        let mon = monitors.monitorContaining(pointX: win.frame.midX, pointY: win.frame.midY)
            ?? monitors.monitors.first
        let home = mon.flatMap { workspaces.activeWorkspaceByMonitor[$0.id] } ?? firstWorkspaceID()
        guard let home else { return }
        windowWorkspace[id] = home
        runtimeState.setAssignment(home, for: id)
    }

    func adoptOrphanWindows(blockingReassign: Bool) {
        if blockingReassign { return }
        for (id, win) in windowsByID {
            guard !win.isIgnored else { continue }
            if isQuakeSessionWindow(win) || quake.windowID == id || isQuakeOwned(id) {
                if var updated = windowsByID[id] {
                    updated.isFloating = true
                    updated.isScratchpad = true
                    windowsByID[id] = updated
                }
                floatingOverrides.insert(id)
                ensureFloatHome(id, win: windowsByID[id] ?? win)
                if workspaces.workspaceID(containing: id) != nil {
                    workspaces.removeWindowEverywhere(id)
                }
                continue
            }
            if win.isFloating || win.isScratchpad {
                ensureFloatHome(id, win: win)
                if workspaces.workspaceID(containing: id) != nil {
                    workspaces.removeWindowEverywhere(id)
                }
                continue
            }
            if workspaces.workspaceID(containing: id) != nil { continue }
            let mon = monitors.monitorContaining(pointX: win.frame.midX, pointY: win.frame.midY)
                ?? monitors.monitors.first
            guard let mon else { continue }
            guard let home = resolveTargetWorkspace(for: win, on: mon) else { continue }
            assignWindow(id, to: home, on: mon)
        }
    }

    func looksLikeMainTiledWindow(_ frame: Rect, usable: Rect) -> Bool {
        let area = max(1, frame.width * frame.height)
        let usableArea = max(1, usable.width * usable.height)
        return area >= usableArea * 0.18
            || (frame.width >= usable.width * 0.4 && frame.height >= usable.height * 0.35)
    }

    func usableAreaNear(_ frame: Rect) -> Rect {
        let mon = monitors.monitorContaining(pointX: frame.midX, pointY: frame.midY)
            ?? primaryMonitor()
            ?? monitors.monitors.first
        guard let mon else {
            return Rect(x: 0, y: 0, width: max(1, frame.width), height: max(1, frame.height))
        }
        return engine.usableArea(monitor: mon.layoutFrame)
    }

    func retileAccidentalFloats(forceClearOverrides: Bool = false) {
        let rules = configStore.config.rules
        for (id, win) in windowsByID {
            guard !win.isIgnored else { continue }
            // Never yank the Quake shell (or sibling Ghostty/Terminal windows) into tiles.
            if isQuakeSessionWindow(win) || quake.windowID == id || isQuakeOwned(id) || win.isScratchpad {
                continue
            }
            if quake.pendingAdoptBundleID != nil, floatingOverrides.contains(id) { continue }
            if AppRules.forcesFloat(rules: rules, window: win) { continue }

            let hasOverride = floatingOverrides.contains(id)
            if hasOverride, !forceClearOverrides { continue }
            if !hasOverride, !win.isFloating { continue }

            let home = windowWorkspace[id]
                ?? runtimeState.assignment(for: id)
            guard let home, workspaces.workspaces[home] != nil else { continue }
            let mon = workspaces.preferredMonitor(forWorkspace: home, monitors: monitors.monitors)
                ?? monitors.monitorContaining(pointX: win.frame.midX, pointY: win.frame.midY)
                ?? monitors.monitors.first
            guard let mon else { continue }
            let usable = engine.usableArea(monitor: mon.layoutFrame)
            let frame = lastFrames[id] ?? win.frame
            guard looksLikeMainTiledWindow(frame, usable: usable) || forceClearOverrides else { continue }

            floatingOverrides.remove(id)
            var cleared = win
            cleared.isFloating = false
            windowsByID[id] = cleared
            if workspaces.workspaceID(containing: id) != home {
                assignWindow(id, to: home, on: mon)
            }
        }
    }

    func syncColumnTilesNotFloat() {
        let rules = configStore.config.rules
        for (id, var win) in windowsByID {
            if isQuakeSessionWindow(win) {
                // Quake session windows must leave columns, not lose scratchpad flags.
                if workspaces.workspaceID(containing: id) != nil {
                    workspaces.removeWindowEverywhere(id)
                }
                win.isFloating = true
                win.isScratchpad = true
                windowsByID[id] = win
                floatingOverrides.insert(id)
                continue
            }
            if AppRules.forcesFloat(rules: rules, window: win) {
                if workspaces.workspaceID(containing: id) != nil {
                    workspaces.removeWindowEverywhere(id)
                }
                win.isFloating = true
                windowsByID[id] = win
                continue
            }
            guard workspaces.workspaceID(containing: id) != nil else { continue }
            if win.isFloating || win.isScratchpad || floatingOverrides.contains(id) {
                floatingOverrides.remove(id)
                win.isFloating = false
                win.isScratchpad = false
                windowsByID[id] = win
            }
        }
    }

    func shouldEjectMissingFromColumns(_ id: WindowID, missingCount: Int) -> Bool {
        // Park/minimize during visibility must not strip column slots.
        if isApplyingVisibility { return false }
        // After sleep AX is incomplete for several seconds — never eject mid-recovery.
        if isResumeRecovering || Date() < resumeRecoveryEligibleUntil { return false }
        // During explicit move / reassign, AX often drops windows mid park-reveal.
        if Date() < suppressIngestReassignUntil { return false }
        let age = Date().timeIntervalSince(windowFirstTrackedAt[id] ?? .distantPast)
        if age < newWindowColumnGrace { return missingCount >= 3 }
        return missingCount >= 2
    }

    func settleNewTiledWindows(_ ids: Set<WindowID>) {
        guard !ids.isEmpty else { return }
        let rules = configStore.config.rules
        for id in ids {
            guard var win = windowsByID[id], !win.isIgnored else { continue }
            if quake.windowID == id || isQuakeOwned(id) || isQuakeSessionWindow(win) { continue }
            if AppRules.forcesFloat(rules: rules, window: win) { continue }
            if floatingOverrides.contains(id) { continue }
            let usable = usableAreaNear(win.frame)
            if !looksLikeMainTiledWindow(win.frame, usable: usable) {
                // Popup (WhatsApp emoji, etc.) — keep out of columns.
                win.isFloating = true
                windowsByID[id] = win
                floatingOverrides.insert(id)
                ensureFloatHome(id, win: win)
                continue
            }

            floatingOverrides.remove(id)
            win.isFloating = false
            win.isScratchpad = false
            windowsByID[id] = win

            let monitor = monitors.monitorContaining(pointX: win.frame.midX, pointY: win.frame.midY)
                ?? primaryMonitor()
                ?? monitors.monitors.first
            guard let monitor else { continue }
            let home = windowWorkspace[id]
                ?? runtimeState.assignment(for: id)
                ?? savedHome(for: win, id: id)
                ?? (isInPostLaunchLayoutGrace() ? nil : resolveTargetWorkspace(for: win, on: monitor))
            guard let home, workspaces.workspaces[home] != nil else { continue }
            if workspaces.workspaceID(containing: id) == nil {
                assignWindow(id, to: home, on: monitor)
            }
        }
        // Mass snap of every "added" tile after update relaunch dumps all apps onto the active WS.
        if isInPostLaunchLayoutGrace() || needsLayoutRecovery(force: false) { return }
        let homes = Set(ids.compactMap { workspaces.workspaceID(containing: $0) })
        for home in homes where isHomeActiveOnAnyMonitor(home) {
            snapWorkspaceTilesAfterColumnChange(home)
        }
    }

    func toggleFloatFocused() {
        guard let id = actionTargetWindowID() else { return }
        toggleFloat(id)
    }

    func toggleFloat(_ id: WindowID) {
        setFloat(id, floating: !(windowsByID[id]?.isFloating ?? false))
    }

    func setFloatFocused(_ floating: Bool) {
        guard let id = actionTargetWindowID() else { return }
        setFloat(id, floating: floating)
    }

    func setFloat(_ id: WindowID, floating: Bool) {
        guard var win = windowsByID[id] else { return }
        // Quake scratchpad is always floating.
        if quake.windowID == id { return }
        win.isFloating = floating
        win.isScratchpad = false
        windowsByID[id] = win
        if floating {
            floatingOverrides.insert(id)
            // Keep a home workspace so inactive floats can be parked on switch.
            if windowWorkspace[id] == nil {
                let home = workspaces.workspaceID(containing: id)
                    ?? primaryMonitor().flatMap { workspaces.activeWorkspaceByMonitor[$0.id] }
                if let home {
                    windowWorkspace[id] = home
                    runtimeState.setAssignment(home, for: id)
                }
            }
            workspaces.removeWindowEverywhere(id)
        } else {
            floatingOverrides.remove(id)
            let fallbackMon = primaryMonitor() ?? monitors.monitors.first
            guard let fallbackMon else {
                persistRuntimeState()
                applyWorkspaceVisibility(animated: false)
                refreshChrome()
                return
            }
            let home = windowWorkspace[id]
                ?? resolveTargetWorkspace(for: win, on: fallbackMon)
                ?? workspaces.activeWorkspaceByMonitor[fallbackMon.id]
                ?? "1"
            let placeOn = workspaces.preferredMonitor(forWorkspace: home, monitors: monitors.monitors)
                ?? monitors.monitors.first(where: { workspaces.activeWorkspaceByMonitor[$0.id] == home })
                ?? fallbackMon
            assignWindow(id, to: home, on: placeOn)
        }
        persistRuntimeState()
        relayout(animated: false)
        refreshChrome()
    }

    func closeWindow(_ id: WindowID) {
        if id == quake.windowID || isQuakeOwned(id) {
            handleQuakeWindowClosed()
            persistRuntimeState()
            refreshChrome()
            return
        }
        let pid = id.pid
        let bundleID = windowsByID[id]?.bundleID
        let wasLayoutTile = windowsByID[id]?.isTiled == true
            || workspaces.workspaceID(containing: id) != nil
        _ = ax.closeWindow(id)
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
        if !isLayoutMutationFrozen {
            persistRuntimeState()
        }
        relayout(animated: false, on: layoutScopeMonitor(for: id))
        refreshChrome()
        if wasLayoutTile {
            scheduleQuitIfLastLayoutWindowClosed(pid: pid, bundleID: bundleID, homeWasActive: true)
        }
    }

    func scheduleQuitIfLastLayoutWindowClosed(pid: pid_t, bundleID: String?, homeWasActive: Bool) {
        guard homeWasActive else { return }
        guard !isBootstrapping, !isResumeRecovering, !isLayoutMutationFrozen else { return }
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        let bid = (bundleID ?? "").lowercased()
        if bid.hasPrefix("dev.alwm") || bid.contains(".alwm") { return }
        if bid == "com.apple.finder" { return }
        if bid.hasPrefix("com.apple.dock") || bid.hasPrefix("com.apple.systemuiserver") { return }
        // Never quit the Quake shell — new tabs/windows must not kill Ghostty/Terminal.
        if let qid = quake.windowID, qid.pid == pid { return }
        if let session = quakeSessionBundleID()?.lowercased(), bid == session { return }
        if windowsByID.values.contains(where: { $0.id.pid == pid && $0.isScratchpad }) { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.ax.scanAll()
            // Soft-missing ghosts stay in windowsByID briefly — only live AX windows count.
            let liveSamePid = self.ax.currentWindows.contains {
                $0.id.pid == pid && !$0.isIgnored && !$0.isScratchpad
                    && ($0.frame.width > 40 && $0.frame.height > 40)
            }
            if liveSamePid { return }
            if self.windowsByID.values.contains(where: { $0.id.pid == pid && $0.isScratchpad }) { return }
            if let qid = self.quake.windowID, qid.pid == pid { return }
            self.logMove("quit last-window pid=\(pid) bundle=\(bundleID ?? "?")")
            self.quitApp(pid: pid)
        }
    }

    func quitApp(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        let ids = windowsByID.keys.filter { $0.pid == pid }
        app.terminate()
        for id in ids {
            workspaces.removeWindowEverywhere(id)
            windowsByID.removeValue(forKey: id)
            windowWorkspace.removeValue(forKey: id)
            floatingOverrides.remove(id)
            savedFrames.removeValue(forKey: id)
            lastFrames.removeValue(forKey: id)
            runtimeState.setAssignment(nil, for: id)
            missingScanCounts.removeValue(forKey: id)
        }
        if !isLayoutMutationFrozen {
            persistRuntimeState()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            if let still = NSRunningApplication(processIdentifier: pid), !still.isTerminated {
                still.forceTerminate()
                self.logMove("quit force pid=\(pid)")
            }
            self.ax.scanAll()
            self.ingest(windows: self.ax.currentWindows)
            self.applyWorkspaceVisibility(animated: false)
            self.refreshChrome()
        }
        refreshChrome()
    }

}
