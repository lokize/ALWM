import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC
import AlwmPluginAPI

// MARK: - Runtime persistence — sticky maps, layout snapshots

extension WindowManager {
    func loadStickyAssignmentsFromDisk() {
        for (token, wsID) in runtimeState.snapshot.windowWorkspace {
            guard workspaces.workspaces[wsID] != nil else { continue }
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let pid = Int32(parts[0]),
                  let winNum = Int(parts[1]) else { continue }
            windowWorkspace[WindowID(pid: pid, windowNumber: winNum)] = wsID
        }
    }

    func rematchStickyFromSavedLayouts() {
        var used = Set<WindowID>()
        let liveByToken = Dictionary(uniqueKeysWithValues: windowsByID.keys.map { ($0.token, $0) })
        // Prefer disk layout order so multi-window apps reclaim distinct windows per WS.
        for wsID in runtimeState.snapshot.workspaceLayouts.keys.sorted() {
            guard let snap = runtimeState.snapshot.workspaceLayouts[wsID],
                  workspaces.workspaces[wsID] != nil
            else { continue }
            let refs = snap.columns.flatMap(\.windows) + snap.floating
            for ref in refs {
                guard let id = resolveLiveWindow(ref, preferredWS: wsID, liveByToken: liveByToken, used: used)
                else { continue }
                used.insert(id)
                windowWorkspace[id] = wsID
                runtimeState.setAssignment(wsID, for: id)
                // Drop any other sticky claiming this live window (stale token ghosts).
                for (other, home) in windowWorkspace where other != id && home == wsID {
                    if other.token == ref.token { continue }
                    if windowsByID[other] == nil {
                        windowWorkspace.removeValue(forKey: other)
                    }
                }
            }
        }
        syncTokenIndex()
    }

    func persistRuntimeStateBeforeUpdate() {
        let wasBootstrapping = isBootstrapping
        let wasResume = isResumeRecovering
        isBootstrapping = false
        isResumeRecovering = false
        let all = Set(workspaces.workspaces.keys)
        persistRuntimeState(forceWorkspaceLayouts: all)
        isBootstrapping = wasBootstrapping
        isResumeRecovering = wasResume
        skipRestoreOnStopForUpdate = true
        NSLog("ALWM: persisted runtime state before update quit")
        logMove("update persist layouts before quit ws=\(all.sorted().joined(separator: ","))")
    }

    func persistRuntimeState(forceWorkspaceLayouts: Set<String> = []) {
        // Never flush partial/empty column maps over a good snapshot during bootstrap.
        if isBootstrapping { return }
        // Wake recovery: AX/columns are mid-rebuild — writing would wipe the pre-sleep layout.
        if isResumeRecovering, forceWorkspaceLayouts.isEmpty { return }

        let savedTiles = savedTiledWindowCount()
        let liveTiles = liveTiledWindowCount()
        let layoutStillRecovering = savedTiles > 0 && liveTiles < savedTiles

        if !layoutStillRecovering {
            for (id, wsID) in windowWorkspace {
                runtimeState.setAssignment(wsID, for: id)
            }
            runtimeState.pruneWindows(keeping: Set(windowsByID.keys))
        }
        for mon in monitors.monitors {
            if let wsID = workspaces.activeWorkspaceByMonitor[mon.id] {
                runtimeState.setLastWorkspace(wsID, on: mon.id)
            }
        }
        let flushLayouts = { [self] (onlyForced: Bool) in
            for (wsID, ws) in self.workspaces.workspaces {
                if onlyForced, !forceWorkspaceLayouts.contains(wsID) { continue }
                self.writeWorkspaceLayoutSnapshot(wsID: wsID, ws: ws, force: forceWorkspaceLayouts.contains(wsID))
            }
        }
        if layoutStillRecovering {
            for (wsID, ws) in workspaces.workspaces {
                let force = forceWorkspaceLayouts.contains(wsID)
                if force {
                    writeWorkspaceLayoutSnapshot(wsID: wsID, ws: ws, force: true)
                    continue
                }
                let existing = runtimeState.workspaceLayout(for: wsID)
                let existingTiles = existing?.columns.reduce(0) { $0 + $1.windows.count } ?? 0
                let liveTiles = ws.columns.reduce(0) { $0 + $1.windows.count }
                // Width / ratio edits must persist even while tile recovery is incomplete.
                if liveTiles >= existingTiles {
                    writeWorkspaceLayoutSnapshot(wsID: wsID, ws: ws, force: false)
                }
            }
            runtimeState.save()
            return
        }
        flushLayouts(false)
        if let qid = quake.windowID {
            runtimeState.setQuakeWindowToken(qid.token)
        }
        syncBundleWorkspaceFromLayouts()
        runtimeState.save()
    }

    func writeWorkspaceLayoutSnapshot(wsID: String, ws: WorkspaceState, force: Bool = false) {
        let floatingRefs = windowsByID.values
            .filter {
                (floatingOverrides.contains($0.id) || $0.isScratchpad || quake.windowID == $0.id)
                    && windowWorkspace[$0.id] == wsID
            }
            .map { RuntimeStateStore.WindowRef(window: $0) }
            .sorted { $0.token < $1.token }
        let columns = ws.columns.map { col in
            RuntimeStateStore.ColumnSnapshot(
                windows: col.windows.compactMap { id -> RuntimeStateStore.WindowRef? in
                    guard !isQuakeOwned(id) else { return nil }
                    guard let win = windowsByID[id] else { return nil }
                    if AppRules.forcesFloat(rules: configStore.config.rules, window: win) { return nil }
                    return RuntimeStateStore.WindowRef(window: win)
                },
                width: col.width,
                isMaximized: col.isMaximized,
                restoreWidth: col.restoreWidth
            )
        }
        let existing = runtimeState.workspaceLayout(for: wsID)
        let newTileCount = columns.reduce(0) { $0 + $1.windows.count }
        let existingTileCount = existing?.columns.reduce(0) { $0 + $1.windows.count } ?? 0
        if !force {
            let existingTokens = Set((existing?.columns ?? []).flatMap(\.windows).map(\.token))
            let newTokens = Set(columns.flatMap(\.windows).map(\.token))
            let removedTokens = existingTokens.subtracting(newTokens)
            let liveTokens = Set(windowsByID.keys.map(\.token))
            let removedStillTracked = removedTokens.contains(where: { liveTokens.contains($0) })
            if newTileCount == 0, existingTileCount > 0, removedStillTracked { return }
            if existingTileCount > newTileCount, removedStillTracked { return }
            let existingColCount = existing?.columns.filter { !$0.windows.isEmpty }.count ?? 0
            let newColCount = columns.filter { !$0.windows.isEmpty }.count
            if existingColCount > newColCount, removedStillTracked { return }
        }
        let layout = RuntimeStateStore.WorkspaceLayoutSnapshot(
            columns: columns,
            focusedColumn: ws.focusedColumn,
            focusedWindowInColumn: Dictionary(
                uniqueKeysWithValues: ws.focusedWindowInColumn.map { (String($0.key), $0.value) }
            ),
            viewOffset: ws.viewOffset,
            leafWeights: ws.leafWeights,
            floating: floatingRefs
        )
        runtimeState.setWorkspaceLayout(layout, for: wsID)
    }

    func syncBundleWorkspaceFromLayouts() {
        var counts: [String: Int] = [:]
        var soleHome: [String: String] = [:]
        for (wsID, layout) in runtimeState.snapshot.workspaceLayouts {
            for ref in layout.columns.flatMap(\.windows) + layout.floating {
                guard let bid = ref.bundleID, !bid.isEmpty else { continue }
                counts[bid, default: 0] += 1
                soleHome[bid] = wsID
            }
        }
        for (bid, count) in counts where count == 1 {
            if let wsID = soleHome[bid] {
                runtimeState.setBundleAssignment(wsID, for: bid)
            }
        }
    }

    func savedBundleInstanceCount(_ bundleID: String) -> Int {
        runtimeState.snapshot.workspaceLayouts.values.reduce(0) { partial, layout in
            partial + (layout.columns.flatMap(\.windows) + layout.floating)
                .filter { $0.bundleID == bundleID }.count
        }
    }

    func liveBundleInstanceCount(_ bundleID: String, pid: pid_t? = nil) -> Int {
        windowsByID.values.filter { win in
            guard win.bundleID == bundleID, !win.isIgnored else { return false }
            if let pid, win.id.pid != pid { return false }
            return missingScanCounts[win.id] == nil
        }.count
    }

    func isSingleBundleInstance(_ bundleID: String, pid: pid_t? = nil) -> Bool {
        savedBundleInstanceCount(bundleID) <= 1 && liveBundleInstanceCount(bundleID, pid: pid) <= 1
    }

    func savedHome(for win: ManagedWindow, id: WindowID) -> String? {
        if let sticky = stickyHome(for: id) { return sticky }

        for wsID in runtimeState.snapshot.workspaceLayouts.keys.sorted() {
            guard workspaces.workspaces[wsID] != nil,
                  let snap = runtimeState.snapshot.workspaceLayouts[wsID]
            else { continue }
            for ref in snap.columns.flatMap(\.windows) + snap.floating {
                guard windowMatchesSavedRef(win, ref: ref) else { continue }
                if refSlotTaken(ref: ref, workspaceID: wsID, except: id) { continue }
                return wsID
            }
        }

        if let bid = win.bundleID, !bid.isEmpty,
           isSingleBundleInstance(bid, pid: id.pid),
           let ws = runtimeState.bundleAssignment(for: bid),
           workspaces.workspaces[ws] != nil {
            return ws
        }
        return nil
    }

    func refSlotTaken(
        ref: RuntimeStateStore.WindowRef,
        workspaceID: String,
        except id: WindowID
    ) -> Bool {
        guard let ws = workspaces.workspaces[workspaceID] else { return false }
        for col in ws.columns {
            for wid in col.windows where wid != id {
                if wid.token == ref.token { return true }
                if let other = windowsByID[wid], windowMatchesSavedRef(other, ref: ref) { return true }
            }
        }
        return false
    }

    func windowMatchesSavedRef(_ win: ManagedWindow, ref: RuntimeStateStore.WindowRef) -> Bool {
        if win.id.token == ref.token { return true }
        if let bid = ref.bundleID, !bid.isEmpty, bid == win.bundleID {
            let rt = Self.normalizedWindowTitle(ref.title)
            let wt = Self.normalizedWindowTitle(win.title)
            if !rt.isEmpty {
                if wt == rt { return true }
                if Self.titlesLooselyMatch(rt, wt) { return true }
                // Title churn (Discord channels, Safari tabs) — only when truly one instance.
                // Disk alone saying "1" used to steal the other live Safari window.
                return isSingleBundleInstance(bid, pid: win.id.pid)
            }
            return isSingleBundleInstance(bid, pid: win.id.pid)
        }
        if !ref.appName.isEmpty, ref.appName == win.appName {
            let rt = Self.normalizedWindowTitle(ref.title)
            let wt = Self.normalizedWindowTitle(win.title)
            if !rt.isEmpty, wt == rt { return true }
        }
        return false
    }

    func stickyHome(for id: WindowID) -> String? {
        if let sticky = windowWorkspace[id], workspaces.workspaces[sticky] != nil { return sticky }
        if let saved = runtimeState.assignment(for: id), workspaces.workspaces[saved] != nil { return saved }
        return nil
    }

    func resolveLiveWindow(
        _ ref: RuntimeStateStore.WindowRef,
        preferredWS: String,
        liveByToken: [String: WindowID],
        used: Set<WindowID>
    ) -> WindowID? {
        // Token match wins only when the window is free or already sticky to this WS.
        if let id = tokenByWindowToken[ref.token] ?? liveByToken[ref.token], !used.contains(id) {
            if let home = stickyHome(for: id), home != preferredWS { return nil }
            return id
        }

        let refTitle = Self.normalizedWindowTitle(ref.title)
        let refBundle = ref.bundleID
        let refApp = ref.appName

        let pool = windowsByID.values.filter { win in
            guard !used.contains(win.id), win.isTiled || win.isFloating else { return false }
            // Never claim a window that already belongs to another workspace.
            if let home = stickyHome(for: win.id), home != preferredWS { return false }
            return true
        }

        // Prefer candidates already sticky to this workspace, then unassigned.
        func rank(_ win: ManagedWindow) -> Int {
            let home = stickyHome(for: win.id) ?? workspaces.workspaceID(containing: win.id)
            if home == preferredWS { return 0 }
            if home == nil { return 1 }
            return 2
        }

        func sortedByRank(_ hits: [ManagedWindow]) -> [ManagedWindow] {
            hits.sorted {
                if rank($0) != rank($1) { return rank($0) < rank($1) }
                return $0.id.token < $1.id.token
            }
        }

        // 1) Exact title + bundle (or app name).
        if !refTitle.isEmpty {
            if let bid = refBundle, !bid.isEmpty {
                let hits = sortedByRank(pool.filter {
                    $0.bundleID == bid && Self.normalizedWindowTitle($0.title) == refTitle
                })
                if let hit = hits.first { return hit.id }
            }
            if !refApp.isEmpty {
                let hits = sortedByRank(pool.filter {
                    $0.appName == refApp && Self.normalizedWindowTitle($0.title) == refTitle
                })
                if let hit = hits.first { return hit.id }
            }

            // 1b) Fuzzy title (Safari/Discord tabs change often after the snapshot).
            if let bid = refBundle, !bid.isEmpty {
                let hits = sortedByRank(pool.filter {
                    $0.bundleID == bid && Self.titlesLooselyMatch(refTitle, Self.normalizedWindowTitle($0.title))
                })
                if let hit = hits.first { return hit.id }
            }
        }

        // 2) Same bundle: only unassigned / already-home candidates (never other WS stickies).
        // Multi-window apps (two Safaris on WS1/WS4) each take the next unused window.
        if let bid = refBundle, !bid.isEmpty {
            let sameBundle = sortedByRank(pool.filter {
                $0.bundleID == bid && (stickyHome(for: $0.id) == nil || stickyHome(for: $0.id) == preferredWS)
            })
            if let hit = sameBundle.first { return hit.id }
        }

        return nil
    }

    func restoreWorkspaceLayoutsFromDisk() {
        var used = Set<WindowID>()
        // Stable order so multi-window apps (e.g. Safari on WS1 + WS2) claim distinct windows.
        for wsID in runtimeState.snapshot.workspaceLayouts.keys.sorted() {
            restoreWorkspaceLayout(for: wsID, used: &used)
        }
        let ejected = ejectWindowsListedOutsideStickyHome()
        if !ejected.isEmpty {
            persistRuntimeState(forceWorkspaceLayouts: ejected)
        }
    }

    func refreshWorkspaceLayoutFromSnapshot(for wsID: String) {
        guard let snap = runtimeState.snapshot.workspaceLayouts[wsID],
              !snap.columns.isEmpty,
              workspaces.workspaces[wsID] != nil
        else { return }

        var used = Set<WindowID>()
        for (otherID, otherWS) in workspaces.workspaces where otherID != wsID {
            for col in otherWS.columns {
                used.formUnion(col.windows)
            }
        }
        for (id, home) in windowWorkspace where home != wsID {
            used.insert(id)
        }

        let liveByToken = Dictionary(uniqueKeysWithValues: windowsByID.keys.map { ($0.token, $0) })
        let rules = configStore.config.rules
        var columns: [Column] = []
        var claimed = Set<WindowID>()

        for colSnap in snap.columns {
            var ids: [WindowID] = []
            for ref in colSnap.windows {
                guard let id = resolveAssignedLiveWindow(
                    ref,
                    workspaceID: wsID,
                    liveByToken: liveByToken,
                    used: used
                ), let win = windowsByID[id], win.isTiled else { continue }
                if AppRules.forcesFloat(rules: rules, window: win) { continue }
                ids.append(id)
                used.insert(id)
                claimed.insert(id)
            }
            if !ids.isEmpty {
                columns.append(Column(
                    windows: ids,
                    width: colSnap.width,
                    isMaximized: colSnap.isMaximized,
                    restoreWidth: colSnap.restoreWidth
                ))
            }
        }

        let leftovers = windowsByID.keys.filter { id in
            guard !used.contains(id), let win = windowsByID[id], win.isTiled else { return false }
            return belongsToWorkspace(id, wsID)
        }
        for id in leftovers.sorted(by: { $0.token < $1.token }) {
            columns.append(Column(windows: [id], width: 0))
            used.insert(id)
        }

        guard !columns.isEmpty else { return }

        if !claimed.isEmpty {
            for id in claimed {
                workspaces.removeWindowEverywhere(id)
            }
        }

        guard var ws = workspaces.workspaces[wsID] else { return }
        let liveBefore = ws
        mergeLiveColumnGeometry(from: liveBefore, into: &columns)
        ws.columns = columns
        ws.focusedColumn = min(max(0, snap.focusedColumn), max(0, columns.count - 1))
        ws.focusedWindowInColumn = Dictionary(
            uniqueKeysWithValues: snap.focusedWindowInColumn.compactMap { key, value -> (Int, Int)? in
                guard let k = Int(key) else { return nil }
                return (k, value)
            }
        )
        ws.viewOffset = liveBefore.viewOffset
        let liveTokenSets = liveBefore.columns.map { Set($0.windows.map(\.token)) }
        let newTokenSets = columns.map { Set($0.windows.map(\.token)) }
        if liveTokenSets == newTokenSets, !liveBefore.leafWeights.isEmpty {
            ws.leafWeights = liveBefore.leafWeights
        } else {
            ws.leafWeights = remappedLeafWeights(from: snap, columns: columns)
            for (token, weight) in liveBefore.leafWeights where ws.leafWeights[token] == nil {
                ws.leafWeights[token] = weight
            }
        }
        syncColumnWidthsToUsable(workspace: &ws, workspaceID: wsID)
        workspaces.setWorkspace(ws)
    }

    func belongsToWorkspace(_ id: WindowID, _ wsID: String) -> Bool {
        if windowWorkspace[id] == wsID { return true }
        if runtimeState.assignment(for: id) == wsID { return true }
        if workspaces.workspaceID(containing: id) == wsID { return true }
        if stickyHome(for: id) == wsID { return true }
        return false
    }

    func resolveAssignedLiveWindow(
        _ ref: RuntimeStateStore.WindowRef,
        workspaceID: String,
        liveByToken: [String: WindowID],
        used: Set<WindowID>
    ) -> WindowID? {
        if let id = liveByToken[ref.token], !used.contains(id), belongsToWorkspace(id, workspaceID) {
            return id
        }

        let refTitle = Self.normalizedWindowTitle(ref.title)
        let pool = windowsByID.values.filter { win in
            guard !used.contains(win.id), win.isTiled else { return false }
            return belongsToWorkspace(win.id, workspaceID)
        }

        if !refTitle.isEmpty {
            if let bid = ref.bundleID, !bid.isEmpty {
                if let hit = pool.first(where: {
                    $0.bundleID == bid && Self.normalizedWindowTitle($0.title) == refTitle
                }) {
                    return hit.id
                }
                if let hit = pool.first(where: {
                    $0.bundleID == bid && Self.titlesLooselyMatch(refTitle, Self.normalizedWindowTitle($0.title))
                }) {
                    return hit.id
                }
            }
            if !ref.appName.isEmpty,
               let hit = pool.first(where: {
                   $0.appName == ref.appName && Self.normalizedWindowTitle($0.title) == refTitle
               }) {
                return hit.id
            }
        }

        return nil
    }

    func fillZeroColumnWidths(workspace: inout WorkspaceState, workspaceID: String) {
        guard !workspace.columns.isEmpty else { return }
        let mon = monitorForWorkspaceLayout(workspaceID)
        guard let mon else { return }
        let usable = engine.usableArea(monitor: mon.layoutFrame)
        let n = max(1, workspace.columns.count)
        let defaultW = engine.niri.defaultColumnWidth(usable: usable, columnCount: n)
        for i in workspace.columns.indices where workspace.columns[i].width <= 0 {
            workspace.columns[i].width = defaultW
        }
    }

    func monitorForWorkspaceLayout(_ workspaceID: String) -> MonitorInfo? {
        monitors.monitors.first(where: { workspaces.activeWorkspaceByMonitor[$0.id] == workspaceID })
            ?? workspaces.preferredMonitor(forWorkspace: workspaceID, monitors: monitors.monitors)
            ?? monitors.monitors.first
    }

    func syncColumnWidthsToUsable(workspace: inout WorkspaceState, workspaceID: String) {
        guard workspace.layout == .niri, !workspace.columns.isEmpty else { return }
        guard let mon = monitorForWorkspaceLayout(workspaceID) else { return }
        let usable = engine.usableArea(monitor: mon.layoutFrame)
        let n = workspace.columns.count
        fillZeroColumnWidths(workspace: &workspace, workspaceID: workspaceID)
        let contentW = engine.niri.contentWidth(workspace: workspace, usable: usable)
        if engine.niri.columnsShouldFillUsable(count: n), contentW < usable.width - 1.0 {
            engine.niri.normalizeWidthsToFill(workspace: &workspace, usable: usable)
            workspace.viewOffset = 0
            return
        }
        if contentW <= usable.width + 1.0 {
            workspace.viewOffset = 0
            return
        }
        if engine.niri.columnsShouldFillUsable(count: n) {
            engine.niri.normalizeWidthsToFill(workspace: &workspace, usable: usable)
        }
        let afterW = engine.niri.contentWidth(workspace: workspace, usable: usable)
        if afterW <= usable.width + 1.0 {
            workspace.viewOffset = 0
        } else {
            engine.fitAllColumnsOnScreen(workspace: &workspace, usable: usable)
        }
    }

    func scheduleRebalanceWorkspace(_ wsID: String, force: Bool = false) {
        if !force,
           let ws = workspaces.workspaces[wsID], !ws.columns.isEmpty {
            let sig = "\(ws.columns.count):\(structuralSnapSignature(for: ws))"
            if lastSnapSignature[wsID] == sig { return }
        }
        rebalanceWorkItems[wsID]?.cancel()
        let delay = force ? 0.08 : rebalanceDebounce
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.rebalanceWorkItems.removeValue(forKey: wsID)
            guard let ws = self.workspaces.workspaces[wsID], !ws.columns.isEmpty else { return }
            self.rebalanceWorkspaceAfterWindowLeft(wsID, force: force)
        }
        rebalanceWorkItems[wsID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func markStructuralLayoutChange(_ wsID: String) {
        forceTileExpandUntil[wsID] = Date().addingTimeInterval(structuralTileExpandDuration)
    }

    func shouldForceTileExpand(_ wsID: String) -> Bool {
        forceTileExpandUntil[wsID].map { Date() < $0 } ?? false
    }

    func structuralSnapSignature(for ws: WorkspaceState) -> String {
        ws.columns.map { col in
            col.windows.map(\.token).sorted().joined(separator: ",")
        }.joined(separator: "|")
    }

    func snapWorkspaceTilesAfterColumnChange(_ wsID: String) {
        guard !snappingWorkspaces.contains(wsID) else { return }
        snappingWorkspaces.insert(wsID)
        defer { snappingWorkspaces.remove(wsID) }
        guard var ws = workspaces.workspaces[wsID] else { return }
        guard !ws.columns.isEmpty else { return }
        let mon = workspaces.preferredMonitor(forWorkspace: wsID, monitors: monitors.monitors)
            ?? monitors.monitors.first(where: { workspaces.activeWorkspaceByMonitor[$0.id] == wsID })
            ?? primaryMonitor()
        guard let mon else { return }
        syncColumnWidthsToUsable(workspace: &ws, workspaceID: wsID)
        workspaces.setWorkspace(ws)
        ws = workspaces.workspaces[wsID] ?? ws
        let signature = "\(ws.columns.count):\(structuralSnapSignature(for: ws))"
        if lastSnapSignature[wsID] == signature { return }
        lastSnapSignature[wsID] = signature
        markStructuralLayoutChange(wsID)
        visibilityForceReveal = true
        let widths = ws.columns.map { Int($0.width) }.map(String.init).joined(separator: "+")
        logMove("move rebalance source ws=\(wsID) cols=\(ws.columns.count) widths=\(widths)")
        for col in ws.columns {
            for wid in col.windows { lastFrames.removeValue(forKey: wid) }
        }
        guard isHomeActiveOnAnyMonitor(wsID) else { return }
        suppressGeometryEnforce(for: 0.5)
        applyWorkspaceTileLayout(wsID, on: mon, forceReveal: true)
        scheduleTileFrameEnforcement()
        guard shouldForceTileExpand(wsID) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
            guard let self else { return }
            guard self.shouldForceTileExpand(wsID) else { return }
            guard self.isHomeActiveOnAnyMonitor(wsID),
                  let mon = self.monitorForWorkspaceLayout(wsID) else { return }
            if var live = self.workspaces.workspaces[wsID] {
                self.syncColumnWidthsToUsable(workspace: &live, workspaceID: wsID)
                self.workspaces.setWorkspace(live)
            }
            self.applyWorkspaceTileLayout(wsID, on: mon, forceReveal: true)
            self.enforceActiveTileFrames()
        }
    }

    func mergeLiveColumnGeometry(from live: WorkspaceState, into columns: inout [Column]) {
        guard !columns.isEmpty else { return }
        let liveTokenSets = live.columns.map { Set($0.windows.map(\.token)) }
        let newTokenSets = columns.map { Set($0.windows.map(\.token)) }
        if liveTokenSets == newTokenSets {
            for i in columns.indices {
                columns[i].width = live.columns[i].width
                columns[i].isMaximized = live.columns[i].isMaximized
                columns[i].restoreWidth = live.columns[i].restoreWidth
            }
            return
        }
        for i in columns.indices {
            let tokens = Set(columns[i].windows.map(\.token))
            if let liveCol = live.columns.first(where: { Set($0.windows.map(\.token)) == tokens }),
               liveCol.width > 0 {
                columns[i].width = liveCol.width
                columns[i].isMaximized = liveCol.isMaximized
                columns[i].restoreWidth = liveCol.restoreWidth
            } else if i < live.columns.count, live.columns[i].width > 0 {
                columns[i].width = live.columns[i].width
                columns[i].isMaximized = live.columns[i].isMaximized
            }
        }
    }

    func restoreWorkspaceLayout(for wsID: String) {
        var used = Set<WindowID>()
        // Windows already placed on other workspaces must not be stolen.
        for (otherID, ws) in workspaces.workspaces where otherID != wsID {
            for col in ws.columns {
                used.formUnion(col.windows)
            }
        }
        // Sticky map wins even when a column list was emptied (heal / token churn).
        for (id, home) in windowWorkspace where home != wsID {
            used.insert(id)
        }
        for (token, home) in runtimeState.snapshot.windowWorkspace where home != wsID {
            if let id = windowsByID.keys.first(where: { $0.token == token }) {
                used.insert(id)
            }
        }
        restoreWorkspaceLayout(for: wsID, used: &used)
    }

    func restoreWorkspaceLayout(for wsID: String, used: inout Set<WindowID>) {
        guard let snap = runtimeState.snapshot.workspaceLayouts[wsID],
              workspaces.workspaces[wsID] != nil
        else { return }

        let liveByToken = Dictionary(uniqueKeysWithValues: windowsByID.keys.map { ($0.token, $0) })
        let rules = configStore.config.rules
        var columns: [Column] = []
        var claimed = Set<WindowID>()
        for colSnap in snap.columns {
            var ids: [WindowID] = []
            for ref in colSnap.windows {
                guard let id = resolveLiveWindow(ref, preferredWS: wsID, liveByToken: liveByToken, used: used),
                      var win = windowsByID[id]
                else { continue }
                // Sticky home on another workspace must never be overwritten by restore.
                if let home = stickyHome(for: id), home != wsID { continue }
                // Quake scratchpad never restores into a tile column.
                if isQuakeOwned(id) || runtimeState.snapshot.quakeWindowToken == ref.token
                    || isQuakeSessionWindow(win) {
                    win.isFloating = true
                    win.isScratchpad = true
                    windowsByID[id] = win
                    floatingOverrides.insert(id)
                    if isQuakeOwned(id) || runtimeState.snapshot.quakeWindowToken == ref.token {
                        quake.rebind(id)
                    }
                    ensureFloatHome(id, win: win)
                    continue
                }
                // App rules that force float must never be demoted into a tile slot.
                if AppRules.forcesFloat(rules: rules, window: win) {
                    win.isFloating = true
                    windowsByID[id] = win
                    ensureFloatHome(id, win: win)
                    continue
                }
                if win.isFloating, !floatingOverrides.contains(id), quake.windowID != id, !win.isScratchpad {
                    win.isFloating = false
                    windowsByID[id] = win
                }
                guard windowsByID[id]?.isTiled == true else { continue }
                ids.append(id)
                used.insert(id)
                claimed.insert(id)
                windowWorkspace[id] = wsID
                runtimeState.setAssignment(wsID, for: id)
            }
            if !ids.isEmpty {
                columns.append(Column(
                    windows: ids,
                    width: colSnap.width,
                    isMaximized: colSnap.isMaximized,
                    restoreWidth: colSnap.restoreWidth
                ))
            }
        }

        // Leftovers: only windows already sticky to *this* workspace (never by bundleID —
        // that would yank every Safari window into one WS).
        let leftovers = windowsByID.keys.filter { id in
            guard !used.contains(id), let win = windowsByID[id], win.isTiled else { return false }
            return windowWorkspace[id] == wsID || workspaces.workspaceID(containing: id) == wsID
        }
        for id in leftovers.sorted(by: { $0.token < $1.token }) {
            columns.append(Column(windows: [id], width: 0))
            used.insert(id)
            claimed.insert(id)
            windowWorkspace[id] = wsID
            runtimeState.setAssignment(wsID, for: id)
        }

        var ws = workspaces.workspaces[wsID]!
        if !columns.isEmpty {
            for id in claimed {
                workspaces.removeWindowEverywhere(id)
            }
            ws = workspaces.workspaces[wsID]!
            ws.columns = columns
        }
        ws.focusedColumn = min(max(0, snap.focusedColumn), max(0, ws.columns.count - 1))
        ws.focusedWindowInColumn = Dictionary(
            uniqueKeysWithValues: snap.focusedWindowInColumn.compactMap { key, value -> (Int, Int)? in
                guard let k = Int(key) else { return nil }
                return (k, value)
            }
        )
        ws.viewOffset = snap.viewOffset
        ws.leafWeights = remappedLeafWeights(from: snap, columns: ws.columns)
        syncColumnWidthsToUsable(workspace: &ws, workspaceID: wsID)
        workspaces.setWorkspace(ws)

        for ref in snap.floating {
            guard let id = resolveLiveWindow(ref, preferredWS: wsID, liveByToken: liveByToken, used: used),
                  var win = windowsByID[id] else { continue }
            windowWorkspace[id] = wsID
            runtimeState.setAssignment(wsID, for: id)
            if win.isScratchpad || quake.windowID == id {
                floatingOverrides.insert(id)
                win.isFloating = true
                windowsByID[id] = win
                workspaces.removeWindowEverywhere(id)
            }
            used.insert(id)
        }
    }


    func rebalanceWorkspaceAfterWindowLeft(_ wsID: String, force: Bool = false) {
        if !force,
           let last = lastRebalanceAt[wsID],
           Date().timeIntervalSince(last) < rebalanceDebounce {
            return
        }
        lastRebalanceAt[wsID] = Date()
        snapWorkspaceTilesAfterColumnChange(wsID)
    }
}
