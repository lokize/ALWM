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
        // Keep disk sticky map — layout rows can be stale (Safari still listed on WS1 after a
        // move to WS5 when persist refused to shrink WS1). Token→WS from disk wins in that case.
        let diskStickyByToken = runtimeState.snapshot.windowWorkspace

        for id in windowsByID.keys {
            windowWorkspace.removeValue(forKey: id)
            runtimeState.setAssignment(nil, for: id)
        }

        var used = Set<WindowID>()
        let liveByToken = Dictionary(uniqueKeysWithValues: windowsByID.keys.map { ($0.token, $0) })

        // 1) Exact token stickies from disk first (survives stale duplicate layout rows).
        for (token, wsID) in diskStickyByToken {
            guard workspaces.workspaces[wsID] != nil,
                  let id = liveByToken[token] ?? tokenByWindowToken[token],
                  windowsByID[id] != nil,
                  !used.contains(id)
            else { continue }
            used.insert(id)
            windowWorkspace[id] = wsID
            runtimeState.setAssignment(wsID, for: id)
        }

        struct LayoutSlot {
            let wsID: String
            let ref: RuntimeStateStore.WindowRef
        }
        var slots: [LayoutSlot] = []
        for wsID in runtimeState.snapshot.workspaceLayouts.keys.sorted() {
            guard let snap = runtimeState.snapshot.workspaceLayouts[wsID],
                  workspaces.workspaces[wsID] != nil
            else { continue }
            for ref in snap.columns.flatMap(\.windows) + snap.floating {
                if let diskHome = diskStickyByToken[ref.token], diskHome != wsID {
                    logMove("rematch skip stale layout ref tok=\(ref.token) layoutWS=\(wsID) diskWS=\(diskHome)")
                    continue
                }
                slots.append(LayoutSlot(wsID: wsID, ref: ref))
            }
        }

        var filledSlotKeys = Set<String>()
        func slotKey(_ slot: LayoutSlot) -> String {
            "\(slot.wsID)|\(slot.ref.token)|\(slot.ref.bundleID ?? "")|\(Self.normalizedWindowTitle(slot.ref.title))"
        }

        func claim(_ id: WindowID, slot: LayoutSlot, reason: String) {
            guard !used.contains(id), windowsByID[id] != nil else { return }
            used.insert(id)
            filledSlotKeys.insert(slotKey(slot))
            windowWorkspace[id] = slot.wsID
            runtimeState.setAssignment(slot.wsID, for: id)
            logMove(
                "rematch \(reason) ws=\(slot.wsID) tok=\(id.token) bundle=\(windowsByID[id]?.bundleID ?? "?") title=\(Self.normalizedWindowTitle(windowsByID[id]?.title ?? ""))"
            )
        }

        func unusedPool() -> [ManagedWindow] {
            windowsByID.values.filter { !used.contains($0.id) && ($0.isTiled || $0.isFloating) }
        }

        // 2a) Global exact title+bundle — prevents WS1 from bundle-stealing the WS5 Safari.
        for slot in slots {
            if filledSlotKeys.contains(slotKey(slot)) { continue }
            if let id = liveByToken[slot.ref.token] ?? tokenByWindowToken[slot.ref.token], used.contains(id) {
                filledSlotKeys.insert(slotKey(slot))
                continue
            }
            let refTitle = Self.normalizedWindowTitle(slot.ref.title)
            guard !refTitle.isEmpty, let bid = slot.ref.bundleID, !bid.isEmpty else { continue }
            let hits = unusedPool().filter {
                $0.bundleID == bid && Self.normalizedWindowTitle($0.title) == refTitle
            }
            if hits.count == 1, let hit = hits.first {
                claim(hit.id, slot: slot, reason: "exact")
            }
        }

        // 2b) Global fuzzy title+bundle when unique; never override an exact slot elsewhere.
        for slot in slots {
            if filledSlotKeys.contains(slotKey(slot)) { continue }
            let refTitle = Self.normalizedWindowTitle(slot.ref.title)
            guard !refTitle.isEmpty, let bid = slot.ref.bundleID, !bid.isEmpty else { continue }
            let hits = unusedPool().filter {
                $0.bundleID == bid && Self.titlesLooselyMatch(refTitle, Self.normalizedWindowTitle($0.title))
            }
            guard hits.count == 1, let hit = hits.first else { continue }
            let hitTitle = Self.normalizedWindowTitle(hit.title)
            let exactElsewhere = slots.contains { other in
                !filledSlotKeys.contains(slotKey(other))
                    && other.wsID != slot.wsID
                    && other.ref.bundleID == bid
                    && Self.normalizedWindowTitle(other.ref.title) == hitTitle
            }
            if exactElsewhere { continue }
            claim(hit.id, slot: slot, reason: "fuzzy")
        }

        // 2c) Remaining slots via resolveLiveWindow (bundle fill), with exact-elsewhere guard.
        for slot in slots {
            if filledSlotKeys.contains(slotKey(slot)) { continue }
            if let id = liveByToken[slot.ref.token] ?? tokenByWindowToken[slot.ref.token], used.contains(id) {
                continue
            }
            guard let id = resolveLiveWindow(
                slot.ref,
                preferredWS: slot.wsID,
                liveByToken: liveByToken,
                used: used,
                preferDiskRematch: true
            ) else { continue }
            if let bid = windowsByID[id]?.bundleID {
                let liveTitle = Self.normalizedWindowTitle(windowsByID[id]?.title ?? "")
                if !liveTitle.isEmpty,
                   slots.contains(where: { other in
                       !filledSlotKeys.contains(slotKey(other))
                           && other.wsID != slot.wsID
                           && other.ref.bundleID == bid
                           && Self.normalizedWindowTitle(other.ref.title) == liveTitle
                   }) {
                    logMove(
                        "rematch defer bundle-claim tok=\(id.token) fromWS=\(slot.wsID) title=\(liveTitle) — exact slot elsewhere"
                    )
                    continue
                }
            }
            claim(id, slot: slot, reason: "layout")
        }
        syncTokenIndex()
    }

    func persistRuntimeStateBeforeUpdate() {
        let wasBootstrapping = isBootstrapping
        let wasResume = isResumeRecovering
        let wasDestructive = allowDestructiveLayoutFlush
        isBootstrapping = false
        isResumeRecovering = false
        allowDestructiveLayoutFlush = true
        let all = Set(workspaces.workspaces.keys)
        persistRuntimeState(forceWorkspaceLayouts: all)
        allowDestructiveLayoutFlush = wasDestructive
        isBootstrapping = wasBootstrapping
        isResumeRecovering = wasResume
        skipRestoreOnStopForUpdate = true
        NSLog("ALWM: persisted runtime state before update quit")
        logMove("update persist layouts before quit ws=\(all.sorted().joined(separator: ","))")
    }

    func persistRuntimeState(forceWorkspaceLayouts: Set<String> = []) {
        // Never flush partial/empty column maps over a good snapshot during bootstrap.
        if isBootstrapping { return }
        // Wake recovery: AX/columns are mid-rebuild — never write layouts (even forced).
        // Callers that must flush (sleep prepare / post-recovery) clear `isResumeRecovering` first.
        if isResumeRecovering { return }

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
                // Never bypass shrink guards on a forced flush unless the caller
                // explicitly opts in via `allowDestructiveLayoutFlush`.
                let forceWrite = forceWorkspaceLayouts.contains(wsID) && allowDestructiveLayoutFlush
                self.writeWorkspaceLayoutSnapshot(wsID: wsID, ws: ws, force: forceWrite)
            }
        }
        if layoutStillRecovering {
            for (wsID, ws) in workspaces.workspaces {
                let force = forceWorkspaceLayouts.contains(wsID) && allowDestructiveLayoutFlush
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
            // Only treat a removal as "AX blip" if the live window still belongs HERE.
            // Moving Safari WS1→WS5 leaves the window alive, so the old guard refused to
            // update WS1 — disk kept Safari on WS1, restore always stole it back (logs).
            let removedStillHomeHere = removedTokens.contains { token in
                guard let id = windowsByID.keys.first(where: { $0.token == token })
                        ?? tokenByWindowToken[token]
                else {
                    // Sleep soft-persist: AX often drops tokens right before sleep — fail closed.
                    return softPersistProtectMissingTokens
                }
                let home = authoritativeHome(for: id)
                    ?? windowWorkspace[id]
                    ?? runtimeState.assignment(for: id)
                    ?? workspaces.workspaceID(containing: id)
                return home == nil || home == wsID
            }
            if newTileCount == 0, existingTileCount > 0, removedStillHomeHere { return }
            if existingTileCount > newTileCount, removedStillHomeHere { return }
            let existingColCount = existing?.columns.filter { !$0.windows.isEmpty }.count ?? 0
            let newColCount = columns.filter { !$0.windows.isEmpty }.count
            if existingColCount > newColCount, removedStillHomeHere { return }
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

    func refSlotTaken(
        ref: RuntimeStateStore.WindowRef,
        workspaceID: String,
        except id: WindowID
    ) -> Bool {
        if let ws = workspaces.workspaces[workspaceID] {
            for col in ws.columns {
                for wid in col.windows where wid != id {
                    if wid.token == ref.token { return true }
                    if let other = windowsByID[wid], windowMatchesSavedRef(other, ref: ref) { return true }
                }
            }
        }
        // Sticky map may claim the slot before columns are rebuilt (bootstrap ingest).
        for (wid, home) in windowWorkspace where home == workspaceID && wid != id {
            guard let other = windowsByID[wid] else { continue }
            if wid.token == ref.token { return true }
            if windowMatchesSavedRef(other, ref: ref) { return true }
        }
        return false
    }

    func savedHome(for win: ManagedWindow, id: WindowID) -> String? {
        if let sticky = stickyHome(for: id) { return sticky }

        // Multi-instance apps: only bind via a free disk slot. Never send every Safari to WS1
        // just because one Safari was saved there.
        var candidates: [String] = []
        for wsID in runtimeState.snapshot.workspaceLayouts.keys.sorted() {
            guard workspaces.workspaces[wsID] != nil,
                  let snap = runtimeState.snapshot.workspaceLayouts[wsID]
            else { continue }
            for ref in snap.columns.flatMap(\.windows) + snap.floating {
                guard windowMatchesSavedRef(win, ref: ref) else { continue }
                if refSlotTaken(ref: ref, workspaceID: wsID, except: id) { continue }
                candidates.append(wsID)
                break
            }
        }
        if candidates.count == 1 { return candidates[0] }
        if candidates.count > 1 {
            // Prefer the workspace whose monitor currently hosts this window.
            let frame = ax.currentFrame(of: id) ?? win.frame
            if let host = monitors.monitorContaining(pointX: frame.midX, pointY: frame.midY) {
                for wsID in candidates {
                    if workspaces.preferredMonitor(forWorkspace: wsID, monitors: monitors.monitors)?.id == host.id {
                        return wsID
                    }
                    if workspaces.activeWorkspaceByMonitor[host.id] == wsID {
                        return wsID
                    }
                }
            }
            return candidates[0]
        }

        if let bid = win.bundleID, !bid.isEmpty,
           isSingleBundleInstance(bid, pid: id.pid),
           let ws = runtimeState.bundleAssignment(for: bid),
           workspaces.workspaces[ws] != nil {
            return ws
        }
        return nil
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

    /// True when disk still remembers this window (sticky token or layout title/bundle slot).
    /// Used so a late AX reappear rematches to WS5 instead of snapping onto the active WS2.
    func diskLayoutClaimsWindow(_ id: WindowID, allowFuzzy: Bool) -> Bool {
        if runtimeState.assignment(for: id) != nil { return true }
        if let tokenHome = runtimeState.snapshot.windowWorkspace[id.token],
           workspaces.workspaces[tokenHome] != nil {
            return true
        }
        guard let win = windowsByID[id] else { return false }
        let liveTitle = Self.normalizedWindowTitle(win.title)
        let bid = win.bundleID
        for (_, snap) in runtimeState.snapshot.workspaceLayouts {
            for ref in snap.columns.flatMap(\.windows) + snap.floating {
                if ref.token == id.token { return true }
                guard let bid, let refBid = ref.bundleID, refBid == bid else { continue }
                let refTitle = Self.normalizedWindowTitle(ref.title)
                if !refTitle.isEmpty, !liveTitle.isEmpty {
                    if refTitle == liveTitle { return true }
                    if allowFuzzy, Self.titlesLooselyMatch(refTitle, liveTitle) { return true }
                }
            }
        }
        return false
    }

    func resolveLiveWindow(
        _ ref: RuntimeStateStore.WindowRef,
        preferredWS: String,
        liveByToken: [String: WindowID],
        used: Set<WindowID>,
        preferDiskRematch: Bool = false
    ) -> WindowID? {
        // Token match wins only when the window is free or already sticky to this WS.
        if let id = tokenByWindowToken[ref.token] ?? liveByToken[ref.token], !used.contains(id) {
            if !preferDiskRematch, let home = stickyHome(for: id), home != preferredWS { return nil }
            return id
        }

        let refTitle = Self.normalizedWindowTitle(ref.title)
        let refBundle = ref.bundleID
        let refApp = ref.appName
        let preferredMon = workspaces.preferredMonitor(forWorkspace: preferredWS, monitors: monitors.monitors)

        let pool = windowsByID.values.filter { win in
            guard !used.contains(win.id), win.isTiled || win.isFloating else { return false }
            // During disk rematch, ignore premature stickies from ingest dumps.
            if !preferDiskRematch, let home = stickyHome(for: win.id), home != preferredWS {
                return false
            }
            return true
        }

        // Prefer: already sticky here → on preferred monitor → unassigned → others.
        func rank(_ win: ManagedWindow) -> Int {
            let home = stickyHome(for: win.id) ?? workspaces.workspaceID(containing: win.id)
            if home == preferredWS { return 0 }
            if let preferredMon {
                let frame = ax.currentFrame(of: win.id) ?? win.frame
                if let host = monitors.monitorContaining(pointX: frame.midX, pointY: frame.midY),
                   host.id == preferredMon.id {
                    return 1
                }
            }
            if home == nil { return 2 }
            return 3
        }

        func sortedByRank(_ hits: [ManagedWindow]) -> [ManagedWindow] {
            hits.sorted {
                if rank($0) != rank($1) { return rank($0) < rank($1) }
                return $0.id.token < $1.id.token
            }
        }

        // How many disk slots remain for this bundle across *later* workspaces (sorted id)?
        // Blocks WS1 from same-bundle-claiming every Safari before WS5 gets a turn.
        func remainingDiskSlots(forBundle bid: String) -> Int {
            let keys = runtimeState.snapshot.workspaceLayouts.keys.sorted()
            guard let start = keys.firstIndex(of: preferredWS) else { return 0 }
            var count = 0
            for wsID in keys[start...] {
                guard let snap = runtimeState.snapshot.workspaceLayouts[wsID] else { continue }
                for ref in snap.columns.flatMap(\.windows) + snap.floating {
                    guard ref.bundleID == bid else { continue }
                    // Already satisfied by a used live window sticky/assigned to this later WS?
                    if wsID == preferredWS { count += 1; continue }
                    count += 1
                }
            }
            // Subtract slots already filled in used set for this bundle.
            let usedOfBundle = used.filter { windowsByID[$0]?.bundleID == bid }.count
            // For preferredWS we are about to fill one — remaining includes current ref.
            return max(0, count - usedOfBundle)
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

        // 2) Same bundle: only when this won't starve later workspaces that also saved this app.
        // Multi-window apps (two Safaris on WS1/WS5) each take the next unused window in layout order.
        if let bid = refBundle, !bid.isEmpty {
            let candidates = sortedByRank(pool.filter { win in
                guard win.bundleID == bid else { return false }
                guard preferDiskRematch
                    || stickyHome(for: win.id) == nil
                    || stickyHome(for: win.id) == preferredWS
                else { return false }
                // Never bundle-steal a window whose exact title is saved on another workspace.
                if preferDiskRematch {
                    let liveTitle = Self.normalizedWindowTitle(win.title)
                    if !liveTitle.isEmpty {
                        for (otherWS, snap) in runtimeState.snapshot.workspaceLayouts where otherWS != preferredWS {
                            for otherRef in snap.columns.flatMap(\.windows) + snap.floating {
                                guard otherRef.bundleID == bid else { continue }
                                if Self.normalizedWindowTitle(otherRef.title) == liveTitle {
                                    return false
                                }
                            }
                        }
                    }
                }
                return true
            })
            let liveLeft = candidates.count
            let slotsLeft = remainingDiskSlots(forBundle: bid)
            // If more disk slots than we'll leave after taking one, still OK — take best ranked.
            // If fewer live windows than slots, still take (best effort).
            if liveLeft > 0, slotsLeft >= 1 {
                if let hit = candidates.first { return hit.id }
            }
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
        // Never flush mid wake-recovery — a forced write can replace the pre-sleep snapshot
        // with half-rematched columns (wrong order/widths) before AX settles.
        if !ejected.isEmpty, !isResumeRecovering {
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

    func syncColumnWidthsToUsable(
        workspace: inout WorkspaceState,
        workspaceID: String,
        preserveScrollOverflow: Bool = false
    ) {
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
        // Resume restore: keep saved widths + viewOffset so scroll layouts rematch disk ratios.
        if preserveScrollOverflow { return }
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
        // Sleep/wake: AX drops windows → collapsing columns here used to overwrite good disk layouts.
        if isLayoutMutationFrozen {
            logMove("rebalance skip frozen ws=\(wsID)")
            return
        }
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
            guard !self.isLayoutMutationFrozen else { return }
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
        guard !isLayoutMutationFrozen else {
            logMove("snap skip frozen ws=\(wsID)")
            return
        }
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
        // During resume recovery, skip leftovers — width:0 columns renormalize ratios and
        // break disk width matching before AX finishes rematching.
        let allowLeftovers = !isResumeRecovering && Date() >= resumeRecoveryEligibleUntil
        let leftovers = allowLeftovers
            ? windowsByID.keys.filter { id in
                guard !used.contains(id), let win = windowsByID[id], win.isTiled else { return false }
                return windowWorkspace[id] == wsID || workspaces.workspaceID(containing: id) == wsID
            }
            : []
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
        let preserveOverflow = isResumeRecovering || Date() < resumeRecoveryEligibleUntil
        syncColumnWidthsToUsable(
            workspace: &ws,
            workspaceID: wsID,
            preserveScrollOverflow: preserveOverflow
        )
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
