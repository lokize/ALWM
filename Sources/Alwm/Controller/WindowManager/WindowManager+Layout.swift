import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC
import AlwmPluginAPI

// MARK: - Layout — relayout, frames, visibility, geometry

extension WindowManager {
    func scheduleGeometryEnforce(for id: WindowID) {
        geometryEnforcePending.insert(id)
        geometryEnforceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard Date() >= self.suppressGeometryEnforceUntil else {
                let remaining = self.suppressGeometryEnforceUntil.timeIntervalSinceNow
                self.scheduleGeometryEnforceDebounced(after: max(0.05, remaining + 0.05))
                return
            }
            // Column scroll moves many frames — don't re-enter relayout from AX Moved.
            guard !self.isColumnPanActive else { return }
            // Mouse drag: AX fires Moved continuously; snapping mid-drag feels broken.
            if NSEvent.pressedMouseButtons & (1 << 0) != 0 {
                self.scheduleGeometryEnforceDebounced()
                return
            }
            guard !self.isApplyingVisibility else {
                self.scheduleGeometryEnforceDebounced()
                return
            }
            if self.overlaysCaptureFocus { return }
            let pending = self.geometryEnforcePending
            self.geometryEnforcePending.removeAll()
            guard !pending.isEmpty else { return }

            let activeIDs = Set(self.workspaces.activeWorkspaceByMonitor.values)
            let monitors = self.monitors.monitors.map(\.frame)
            var needsRelayout = false

            for id in pending {
                guard let win = self.windowsByID[id], win.isTiled else { continue }
                guard self.quake.windowID != id else { continue }
                if Date().timeIntervalSince(self.windowFirstTrackedAt[id] ?? .distantPast) < self.newWindowColumnGrace {
                    continue
                }
                let home = self.authoritativeHome(for: id)
                guard let home, activeIDs.contains(home) else { continue }
                guard let ws = self.workspaces.workspaces[home] else { continue }
                // Orphan tile (not in columns) — reinsert then full relayout.
                if self.workspaces.workspaceID(containing: id) != home {
                    self.reinsertOrphanTiles()
                    needsRelayout = true
                    continue
                }
                let mon = self.monitors.monitors.first(where: {
                    self.workspaces.activeWorkspaceByMonitor[$0.id] == home
                }) ?? self.primaryMonitor()
                guard let mon else { continue }
                let expected = self.engine.computeFrames(
                    workspace: ws,
                    windows: self.windowsByID,
                    monitor: mon.layoutFrame,
                    active: true,
                    stackExcluded: self.stackExcludedFromLayout(),
                    layoutExcluded: self.layoutExcludedWindowIDs(for: home)
                ).first(where: { $0.windowID == id })?.frame
                if let expected, self.ax.isSettled(id: id, frame: expected, monitors: monitors) {
                    self.lastFrames[id] = expected
                    continue
                }
                // AX will not shrink below minSize — skip only when the column x/width already match.
                if let expected, let win = self.windowsByID[id],
                   expected.height + 1 < win.minSize.height,
                   let live = self.ax.currentFrame(of: id),
                   abs(live.x - expected.x) < 8,
                   abs(live.width - expected.width) < 8 {
                    continue
                }
                // Electron (WhatsApp/Discord) often refuses exact stack heights — height-only
                // drift must not restart a full relayout or siblings pump forever.
                // Do NOT accept bottom overflow: +80 let tiles sit under the dock and hide
                // WhatsApp's composer until a manual resize.
                if let expected, let live = self.ax.currentFrame(of: id),
                   abs(live.x - expected.x) < 10,
                   abs(live.width - expected.width) < 12,
                   abs(live.y - expected.y) < 48,
                   live.maxY <= expected.maxY + 8 {
                    self.lastFrames[id] = live
                    continue
                }
                if let live = self.ax.currentFrame(of: id),
                   OffscreenParking.isEdgeStrip(live, monitors: monitors) {
                    needsRelayout = true
                    continue
                }
                needsRelayout = true
            }

            if needsRelayout {
                self.suppressGeometryEnforce(for: 0.6)
                let scopeID = pending.first
                self.relayout(animated: false, on: self.layoutScopeMonitor(for: scopeID))
            }
        }
        geometryEnforceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    func scheduleGeometryEnforceDebounced(after delay: TimeInterval = 0.22) {
        geometryEnforceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let any = self.geometryEnforcePending.first else { return }
            self.scheduleGeometryEnforce(for: any)
        }
        geometryEnforceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func ingest(windows: [ManagedWindow]) {
        let rules = configStore.config.rules
        let blockingReassign = Date() < suppressIngestReassignUntil
        let alreadyKnown = Set(windowsByID.keys)
        var mapped: [WindowID: ManagedWindow] = [:]
        for w in windows {
            var applied = AppRules.apply(rules: rules, to: w)
            let pendingCandidate = Self.isPendingQuakeCandidate(
                window: applied,
                pendingBundleID: quake.pendingAdoptBundleID,
                quakeWindowID: quake.windowID,
                alreadyKnown: alreadyKnown
            )
            let quakeSession = isQuakeSessionWindow(applied) || pendingCandidate
            if quakeSession {
                applied.isFloating = true
                applied.isScratchpad = true
                floatingOverrides.insert(w.id)
            } else if floatingOverrides.contains(w.id) {
                applied.isFloating = true
            } else if AppRules.forcesFloat(rules: rules, window: applied) {
                applied.isFloating = true
            } else if let until = forcedTiledUntil[w.id], Date() < until {
                applied.isFloating = false
            } else if !alreadyKnown.contains(w.id) {
                // New windows: Electron often mis-labels *main* windows as dialogs — force tile
                // only when the frame looks like a real app window. Emoji/sticker popups
                // (WhatsApp) must stay floating or they equal-split the workspace.
                let usable = usableAreaNear(applied.frame)
                if looksLikeMainTiledWindow(applied.frame, usable: usable) {
                    applied.isFloating = false
                } else {
                    applied.isFloating = true
                    floatingOverrides.insert(w.id)
                }
            } else if workspaces.workspaceID(containing: w.id) != nil
                || windowWorkspace[w.id] != nil
                || runtimeState.assignment(for: w.id) != nil {
                // Sticky / already-tiled windows stay tiled — AX dialog flags are transient
                // (WhatsApp/Safari) and must not yank them into ⌀ and scramble columns.
                applied.isFloating = false
            }
            mapped[w.id] = applied
        }

        let previous = Set(windowsByID.keys)
        let next = Set(mapped.keys)
        let added = next.subtracting(previous)
        let removed = previous.subtracting(next)

        // Soft-delete: AX often drops windows briefly during park/minimize.
        // Only forget sticky after several consecutive missing scans.
        var forgotten: Set<WindowID> = []
        var columnsStripped = false
        var strippedLayouts: Set<String> = []
        var lastWindowQuitPIDs: [(pid: pid_t, bundleID: String?, homeWasActive: Bool)] = []
        for id in removed {
            if id == quake.windowID {
                // Soft-delete: ⌘T / tab chrome must not immediately tear Quake down.
                let count = (missingScanCounts[id] ?? 0) + 1
                missingScanCounts[id] = count
                if count >= 6 {
                    scheduleConfirmQuakeClosed(suspectID: id)
                }
                continue
            }
            // Floats (Finder etc.) leave the bar immediately — soft-delete only helps tiled park blips.
            let isFloatGhost = windowsByID[id]?.isFloating == true && id != quake.windowID
            let home = windowWorkspace[id] ?? workspaces.workspaceID(containing: id)
            let homeWasActive = home.map { isHomeActiveOnAnyMonitor($0) } ?? false
            // User clicked the red X on an active workspace — forget quickly (not a park blip).
            let closedOnActive = homeWasActive
                && workspaces.workspaceID(containing: id) != nil
                && !isApplyingVisibility
                && !isResumeRecovering
            let threshold = (id == quake.windowID) ? 20
                : (isFloatGhost ? 2 : (closedOnActive ? 2 : 4))
            let count = (missingScanCounts[id] ?? 0) + 1
            missingScanCounts[id] = count
            // Closed windows vanish from AX — drop the column slot once stable (not on first blip).
            if workspaces.workspaceID(containing: id) != nil, !isMoveProtectedTile(id) {
                if let home = workspaces.workspaceID(containing: id) {
                    strippedLayouts.insert(home)
                }
                if shouldEjectMissingFromColumns(id, missingCount: count)
                    || (closedOnActive && count >= 1) {
                    let pid = id.pid
                    let bid = windowsByID[id]?.bundleID
                    workspaces.removeWindowEverywhere(id)
                    windowWorkspace.removeValue(forKey: id)
                    runtimeState.setAssignment(nil, for: id)
                    columnsStripped = true
                    if let home {
                        pruneVacantColumnSlots(wsID: home)
                        strippedLayouts.insert(home)
                    }
                    if closedOnActive {
                        lastWindowQuitPIDs.append(
                            (pid: pid, bundleID: bid, homeWasActive: true)
                        )
                    }
                }
            }
            if count >= threshold {
                forgotten.insert(id)
                let home = windowWorkspace[id] ?? workspaces.workspaceID(containing: id)
                let homeWasActive = home.map { isHomeActiveOnAnyMonitor($0) } ?? false
                let wasLayoutTile = windowsByID[id]?.isTiled == true
                    || workspaces.workspaceID(containing: id) != nil
                if wasLayoutTile {
                    lastWindowQuitPIDs.append(
                        (pid: id.pid, bundleID: windowsByID[id]?.bundleID, homeWasActive: homeWasActive)
                    )
                }
                if let home = workspaces.workspaceID(containing: id) {
                    strippedLayouts.insert(home)
                }
                if id == quake.windowID {
                    quake.forgetIfFullyGone(windows: [:])
                }
                workspaces.removeWindowEverywhere(id)
                lastFrames.removeValue(forKey: id)
                savedFrames.removeValue(forKey: id)
                floatingOverrides.remove(id)
                windowWorkspace.removeValue(forKey: id)
                runtimeState.setAssignment(nil, for: id)
                missingScanCounts.removeValue(forKey: id)
                windowFirstTrackedAt.removeValue(forKey: id)
                appRuleFramesApplied.remove(id)
            }
            // Keep last known ManagedWindow (until forgotten) so we can still park by sticky id.
        }
        for id in next {
            missingScanCounts.removeValue(forKey: id)
        }
        for id in added where !isBootstrapping {
            windowFirstTrackedAt[id] = Date()
        }
        for id in forgotten {
            windowFirstTrackedAt.removeValue(forKey: id)
        }

        if added.isEmpty && removed.isEmpty && forgotten.isEmpty && !blockingReassign,
           applyTitleOnlyIngest(from: mapped) {
            return
        }

        var ingestScopeMonitor: MonitorInfo?
        if added.isEmpty && forgotten.isEmpty && !blockingReassign {
            for (id, win) in mapped {
                guard let prev = windowsByID[id], prev.frame != win.frame else { continue }
                if let mon = layoutScopeMonitor(for: id) {
                    ingestScopeMonitor = mon
                    break
                }
            }
        }

        // Merge: keep previous entries for soft-missing windows so hide still works.
        var merged = windowsByID
        for (id, win) in mapped { merged[id] = win }
        for id in forgotten {
            merged.removeValue(forKey: id)
        }
        windowsByID = merged
        syncTokenIndex()
        if !isBootstrapping, !isResumeRecovering, !lastWindowQuitPIDs.isEmpty {
            var seen = Set<pid_t>()
            for item in lastWindowQuitPIDs where seen.insert(item.pid).inserted {
                if added.contains(where: { $0.pid == item.pid }) { continue }
                scheduleQuitIfLastLayoutWindowClosed(
                    pid: item.pid,
                    bundleID: item.bundleID,
                    homeWasActive: item.homeWasActive
                )
            }
        }
        if !added.isEmpty, !isBootstrapping {
            for id in added {
                _ = rebindAddedWindowIfTokenChurn(id)
            }
        }
        forcedTiledUntil = forcedTiledUntil.filter { Date() < $0.value }
        forcedFloatVisibleUntil = forcedFloatVisibleUntil.filter { Date() < $0.value }
        forceTileExpandUntil = forceTileExpandUntil.filter { Date() < $0.value }
        // Use merged tracking (soft-missing kept) so a parked quake is not forgotten.
        if let qid = quake.windowID, merged[qid] == nil {
            let count = missingScanCounts[qid] ?? 0
            if count >= 6 {
                scheduleConfirmQuakeClosed(suspectID: qid)
            }
            // Do not call forgetIfFullyGone on first blips — that clears visible Quake on ⌘T.
        }
        quake.markScratchpad(in: &windowsByID)

        syncColumnTilesNotFloat()
        strippedLayouts.formUnion(healBundleTokenChurn())

        // New windows only — never during bootstrap (every window looks "added" on first ingest).
        if !isBootstrapping {
            settleNewTiledWindows(added)
        }

        // Heal accidental floats (AX dialog flag / bad restore) back into tile columns.
        retileAccidentalFloats()
        // App-rule floats (e.g. Finder) must never occupy a tile slot.
        strippedLayouts.formUnion(enforceAppRuleFloats())
        // Quake is sticky-float only — never a tile.
        enforceQuakeFloat()
        // Pending launch / extra shell windows: keep candidates out of columns.
        let quakeStripped = stripPendingQuakeFromColumns()
        recoverQuakeBindingIfNeeded(fromAdded: added)

        // Explicit floats / scratchpads leave columns but keep a home workspace.
        for (id, win) in windowsByID where win.isFloating || win.isScratchpad {
            if isMoveProtectedTile(id) { continue }
            if windowWorkspace[id] == nil {
                if let fromColumn = workspaces.workspaceID(containing: id) {
                    windowWorkspace[id] = fromColumn
                    runtimeState.setAssignment(fromColumn, for: id)
                } else if let mon = monitors.monitorContaining(pointX: win.frame.midX, pointY: win.frame.midY)
                    ?? monitors.monitors.first,
                    let active = workspaces.activeWorkspaceByMonitor[mon.id] {
                    windowWorkspace[id] = active
                    runtimeState.setAssignment(active, for: id)
                }
            }
            if workspaces.workspaceID(containing: id) != nil {
                workspaces.removeWindowEverywhere(id)
            }
            if let home = windowWorkspace[id], isHomeActiveOnAnyMonitor(home) {
                markFloatRevealProtected(id)
            }
        }

        for id in added {
            guard let win = windowsByID[id], win.isTiled else {
                if let win = windowsByID[id], !win.isIgnored {
                    ensureFloatHome(id, win: win)
                    if !isBootstrapping, !blockingReassign,
                       let mon = monitors.monitorContaining(pointX: win.frame.midX, pointY: win.frame.midY)
                        ?? monitors.monitors.first,
                       let active = workspaces.activeWorkspaceByMonitor[mon.id] {
                        windowWorkspace[id] = active
                        runtimeState.setAssignment(active, for: id)
                    }
                }
                continue
            }
            let monitor = monitors.monitorContaining(pointX: win.frame.midX, pointY: win.frame.midY)
                ?? monitors.monitors.first
            guard let monitor else { continue }

            if let preferred = AppRules.preferredWorkspace(rules: rules, window: win),
               workspaces.workspaces[preferred] != nil {
                let rule = AppRules.matching(rules: rules, window: win)
                let targetMon = rule.flatMap { monitorForAppRule($0, window: win) } ?? monitor
                assignWindow(id, to: preferred, on: targetMon)
                continue
            }

            // During workspace switch: never invent placement — sticky only, no shuffle.
            if blockingReassign {
                if let sticky = windowWorkspace[id] ?? runtimeState.assignment(for: id),
                   workspaces.workspaces[sticky] != nil {
                    assignWindow(id, to: sticky, on: monitor)
                }
                continue
            }

            if isBootstrapping || isInPostLaunchLayoutGrace() {
                if let sticky = windowWorkspace[id] ?? runtimeState.assignment(for: id) ?? savedHome(for: win, id: id),
                   workspaces.workspaces[sticky] != nil {
                    assignWindow(id, to: sticky, on: monitor)
                }
                // Leave unassigned for restoreWorkspaceLayouts — do not dump into active WS
                // (that steals multi-window apps from their saved workspaces).
                continue
            }

            if needsLayoutRecovery(force: false) {
                if let home = savedHome(for: win, id: id) ?? windowWorkspace[id].flatMap({ workspaces.workspaces[$0] != nil ? $0 : nil })
                    ?? runtimeState.assignment(for: id).flatMap({ workspaces.workspaces[$0] != nil ? $0 : nil }) {
                    assignWindow(id, to: home, on: monitor)
                }
                continue
            }

            if let home = savedHome(for: win, id: id) {
                assignWindow(id, to: home, on: monitor)
                continue
            }

            let active = workspaces.activeWorkspaceByMonitor[monitor.id]
                ?? resolveTargetWorkspace(for: win, on: monitor)
            if let active {
                assignWindow(id, to: active, on: monitor)
            }
        }

        // Second pass: floats that only got a home above can now be re-tiled (Electron AX dialog flag).
        retileAccidentalFloats()
        // Never dump unassigned tiles onto the active workspace during bootstrap / resume /
        // post-launch grace — that pinned every Safari to MSI/WS1 before rematch could place
        // siblings on WS5 (other display). Leave them for rematchSticky + restoreLayouts.
        if !isBootstrapping, !isResumeRecovering, !isInPostLaunchLayoutGrace() {
            for id in added {
                guard let win = windowsByID[id], win.isTiled else { continue }
                guard workspaces.workspaceID(containing: id) == nil else { continue }
                let monitor = monitors.monitorContaining(pointX: win.frame.midX, pointY: win.frame.midY)
                    ?? monitors.monitors.first
                guard let monitor else { continue }
                let home = windowWorkspace[id]
                    ?? runtimeState.assignment(for: id)
                    ?? workspaces.activeWorkspaceByMonitor[monitor.id]
                guard let home, workspaces.workspaces[home] != nil else { continue }
                assignWindow(id, to: home, on: monitor)
            }
        }

        // Reconcile every tiled window: rules / sticky / columns must agree.
        let activeIDs = Set(workspaces.activeWorkspaceByMonitor.values)
        for (id, win) in windowsByID where win.isTiled {
            let monitor = monitors.monitorContaining(pointX: win.frame.midX, pointY: win.frame.midY)
                ?? monitors.monitors.first
            guard let monitor else { continue }

            if let preferred = AppRules.preferredWorkspace(rules: rules, window: win),
               workspaces.workspaces[preferred] != nil {
                if windowWorkspace[id] != preferred || workspaces.workspaceID(containing: id) != preferred {
                    assignWindow(id, to: preferred, on: monitor)
                }
                continue
            }

            if let home = authoritativeHome(for: id),
               workspaces.workspaces[home] != nil {
                let inHome = workspaces.workspaceID(containing: id) == home
                let homeActive = activeIDs.contains(home)
                let live = ax.currentFrame(of: id) ?? win.frame
                let onScreen = !ax.isMinimized(id)
                    && OffscreenParking.isOnAnyMonitor(live, monitors: monitors.monitors.map(\.frame))

                // Dock / Cmd-Tab: follow the user to the window's home workspace.
                // Never steal the window into the current active WS (that dumped everything into WS1).
                if !homeActive, onScreen, !isBootstrapping, !blockingReassign,
                   !isApplyingVisibility,
                   id == axFocusedWindowID {
                    let homeToFollow = home
                    let liveMon = monitors.monitorContaining(pointX: live.midX, pointY: live.midY)
                        ?? workspaces.preferredMonitor(forWorkspace: home, monitors: monitors.monitors)
                        ?? monitor
                    let monID = liveMon.id
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        // Still not on that workspace (user may have switched already).
                        let activeNow = Set(self.workspaces.activeWorkspaceByMonitor.values)
                        guard !activeNow.contains(homeToFollow) else { return }
                        self.switchWorkspace(id: homeToFollow, on: monID, restoreLayout: false)
                    }
                    continue
                }

                if !inHome {
                    assignWindow(id, to: home, on: monitor)
                }
                continue
            }

            if blockingReassign { continue }

            if let current = workspaces.workspaceID(containing: id) {
                windowWorkspace[id] = current
                runtimeState.setAssignment(current, for: id)
                continue
            }

            guard let home = resolveTargetWorkspace(for: win, on: monitor) else { continue }
            assignWindow(id, to: home, on: monitor)
        }

        // Floats leave columns but MUST keep a home workspace (otherwise they vanish from the bar).
        for (id, win) in windowsByID where !win.isTiled {
            if isMoveProtectedTile(id) { continue }
            if workspaces.workspaceID(containing: id) != nil { continue }
            workspaces.removeWindowEverywhere(id)
            ensureFloatHome(id, win: win)
        }

        // Catch anything still not in a column and not a float with a home (token churn / soft-miss).
        adoptOrphanWindows(blockingReassign: blockingReassign)

        if blockingReassign {
            let stripped = ejectWindowsListedOutsideStickyHome()
            if !stripped.isEmpty {
                persistRuntimeState(forceWorkspaceLayouts: stripped)
            }
        } else {
            runStructuralHealIfNeeded()
        }

        if !isBootstrapping,
           layoutRecoveryAttempts < maxLayoutRecoveryAttempts,
           needsLayoutRecovery(force: false) {
            runLayoutRecoveryIfNeeded(force: false, delay: 0.8)
        }

        for wsID in strippedLayouts {
            scheduleRebalanceWorkspace(wsID, force: columnsStripped)
        }
        if columnsStripped || !strippedLayouts.isEmpty || !forgotten.isEmpty {
            persistRuntimeState(forceWorkspaceLayouts: strippedLayouts)
        }
        if columnsStripped || !strippedLayouts.isEmpty {
            visibilityForceReveal = true
        }
        // During switch suppression, only refresh visibility — avoid animated thrash.
        if quakeStripped {
            // Structural: Quake left the tile tree — snap remaining windows immediately.
            ingestRelayoutWorkItem?.cancel()
            if !shouldDeferVisibilityRefreshFromIngest() {
                scheduleVisibilityRefresh(animated: false, delay: 0)
            }
        } else if columnsStripped || !forgotten.isEmpty {
            ingestRelayoutWorkItem?.cancel()
            // Collapse ghost columns immediately after red-X / soft-delete eject.
            for wsID in strippedLayouts where isHomeActiveOnAnyMonitor(wsID) {
                pruneVacantColumnSlots(wsID: wsID)
                snapWorkspaceTilesAfterColumnChange(wsID)
            }
            if !shouldDeferVisibilityRefreshFromIngest() {
                if blockingReassign, columnsStripped, forgotten.isEmpty {
                    scheduleScopedLayoutRefresh(
                        animated: false,
                        delay: 0.15,
                        monitor: ingestScopeMonitor ?? layoutScopeMonitor()
                    )
                } else if !columnsStripped {
                    scheduleVisibilityRefresh(animated: false, delay: 0)
                }
            }
        } else if blockingReassign {
            if !shouldDeferVisibilityRefreshFromIngest() {
                scheduleVisibilityRefresh(animated: false, delay: 0.05)
            }
        } else if !added.isEmpty {
            let rules = configStore.config.rules
            let addedFloats = Set(added.filter { id in
                guard let win = windowsByID[id] else { return false }
                return win.isFloating || win.isScratchpad || floatingOverrides.contains(id)
                    || AppRules.forcesFloat(rules: rules, window: win)
            })
            for id in addedFloats {
                markFloatRevealProtected(id)
            }
            let addedTiles = Set(added).subtracting(addedFloats)
            ingestRelayoutWorkItem?.cancel()
            if !shouldDeferVisibilityRefreshFromIngest() {
                if !addedTiles.isEmpty {
                    // Snap columns only — a full visibility pass hide/reveals the new tile in a loop.
                    // Mass "added" after relaunch/resume is restore churn — rematch from disk instead
                    // of flattening every Safari onto the active MSI workspace (see move.log).
                    let massRestore = addedTiles.count >= 2
                        && (isInPostLaunchLayoutGrace()
                            || isResumeRecovering
                            || Date() < resumeRecoveryEligibleUntil)
                    if massRestore {
                        logMove(
                            "tile mass-restore rematch added=\(addedTiles.count) ids=\(addedTiles.map(\.token).sorted().joined(separator: ","))"
                        )
                        rematchStickyFromSavedLayouts()
                        restoreWorkspaceLayoutsFromDisk()
                        prepareAllActiveWorkspaceLayouts()
                    } else {
                        let homes = Set(addedTiles.compactMap { workspaces.workspaceID(containing: $0) })
                        for home in homes where isHomeActiveOnAnyMonitor(home) {
                            logMove("tile new-window snap ws=\(home) ids=\(addedTiles.map(\.token).joined(separator: ","))")
                            snapWorkspaceTilesAfterColumnChange(home)
                        }
                    }
                } else if !addedFloats.isEmpty {
                    revealActiveFloats(ids: addedFloats)
                }
            }
        } else if !shouldDeferVisibilityRefreshFromIngest() {
            // Routine AX churn (title/frame) — scope to the affected display so WS5
            // on another monitor is not re-parked/revealed on every ingest tick.
            scheduleScopedLayoutRefresh(
                animated: false,
                delay: 0.35,
                monitor: ingestScopeMonitor ?? layoutScopeMonitor()
            )
        }
        refreshChrome()
    }

    func shouldDeferVisibilityRefreshFromIngest() -> Bool {
        Date() < suppressWorkspaceFollowUntil
            || Date() < suppressIngestReassignUntil
            || isApplyingVisibility
            || overlaysCaptureFocus
    }

    func applyTitleOnlyIngest(from mapped: [WindowID: ManagedWindow]) -> Bool {
        guard Set(mapped.keys) == Set(windowsByID.keys) else { return false }
        var titleChanged = false
        for (id, win) in mapped {
            guard let prev = windowsByID[id] else { return false }
            if prev.isFloating != win.isFloating
                || prev.isIgnored != win.isIgnored
                || prev.isScratchpad != win.isScratchpad
                || prev.frame != win.frame
                || prev.bundleID != win.bundleID
                || prev.appName != win.appName {
                return false
            }
            if prev.title != win.title { titleChanged = true }
        }
        guard titleChanged else { return false }
        for (id, win) in mapped {
            var updated = windowsByID[id]!
            updated.title = win.title
            windowsByID[id] = updated
        }
        refreshStatusItem()
        refreshChrome()
        return true
    }

    func scheduleScopedLayoutRefresh(animated: Bool, delay: TimeInterval, monitor: MonitorInfo?) {
        ingestRelayoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isApplyingVisibility {
                self.scheduleScopedLayoutRefresh(animated: animated, delay: 0.05, monitor: monitor)
                return
            }
            if self.overlaysCaptureFocus { return }
            self.applyFluidLayout(animated: animated, onlyMonitor: monitor)
        }
        ingestRelayoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func scheduleVisibilityRefresh(animated: Bool, delay: TimeInterval) {
        ingestRelayoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isApplyingVisibility {
                // Don't drop — retry shortly after the in-flight apply finishes.
                self.scheduleVisibilityRefresh(animated: animated, delay: 0.05)
                return
            }
            self.applyWorkspaceVisibility(animated: animated)
        }
        ingestRelayoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func relayout(animated: Bool, on monitor: MonitorInfo? = nil) {
        if overlaysCaptureFocus { return }
        applyFluidLayout(animated: animated, onlyMonitor: monitor)
    }

    func relayoutWithFrameRetry(stackAnchor: WindowID? = nil, on monitor: MonitorInfo? = nil) {
        suppressGeometryEnforce(for: 0.45)
        let scope = monitor ?? layoutScopeMonitor(for: stackAnchor)
        applyFluidLayout(animated: false, onlyMonitor: scope)
        if let stackAnchor {
            applyStackColumnFrames(for: stackAnchor)
        }
        scheduleTileFrameEnforcement(stackAnchor: stackAnchor)
    }

    func applyAllActiveStackColumns() {
        if overlaysCaptureFocus { return }
        let activeIDs = Set(workspaces.activeWorkspaceByMonitor.values)
        for wsID in activeIDs {
            guard let ws = workspaces.workspaces[wsID] else { continue }
            for col in ws.columns {
                let tiled = col.windows.filter { id in
                    guard let w = windowsByID[id] else { return false }
                    return !w.isIgnored
                }
                guard tiled.count >= 2, let anchor = tiled.first else { continue }
                applyStackColumnFrames(for: anchor)
            }
        }
    }

    func suppressGeometryEnforce(for seconds: Double) {
        suppressGeometryEnforceUntil = Date().addingTimeInterval(seconds)
    }

    func clampStackTileFrame(_ frame: Rect, usable: Rect) -> Rect {
        var f = frame
        if f.width > usable.width { f.width = usable.width }
        if f.x < usable.x { f.x = usable.x }
        if f.maxX > usable.maxX { f.x = max(usable.x, usable.maxX - f.width) }
        if f.height > usable.height { f.height = usable.height }
        if f.y < usable.y { f.y = usable.y }
        if f.maxY > usable.maxY { f.y = max(usable.y, usable.maxY - f.height) }
        if f.y < usable.y { f.y = usable.y }
        if f.maxY > usable.maxY { f.height = max(48, usable.maxY - f.y) }
        return f
    }

    func tessellateColumnStack(
        _ frames: [(WindowID, Rect)],
        usable: Rect,
        x: Double,
        width: Double
    ) -> [(WindowID, Rect)] {
        let n = frames.count
        guard n >= 1 else { return frames }
        let gap = engine.settings.gap
        let gaps = gap * Double(max(0, n - 1))
        let available = max(48, usable.height - gaps)
        let totalH = frames.reduce(0.0) { $0 + max(1, $1.1.height) }
        var y = usable.y
        var out: [(WindowID, Rect)] = []
        for (index, (id, frame)) in frames.enumerated() {
            let isLast = index == n - 1
            let ratio = max(1, frame.height) / totalH
            let h = isLast ? max(48, usable.maxY - y) : max(48, available * ratio)
            out.append((id, Rect(x: x, y: y, width: width, height: h)))
            y += h + gap
        }
        return out
    }

    func stackExcludedFromLayout() -> Set<WindowID> {
        Set(windowsByID.keys.filter { id in
            guard let win = windowsByID[id], win.isTiled else { return false }
            if cachedIsMinimized(id) { return true }
            if missingScanCounts[id] != nil { return true }
            return false
        })
    }

    func applyWorkspaceColumnTileFrames(
        workspaceID: String,
        monitor: MonitorInfo,
        assignments: [FrameAssignment],
        forceReveal: Bool,
        columnIndex: Int? = nil
    ) -> Int {
        guard let ws = workspaces.workspaces[workspaceID] else { return 0 }
        let usable = engine.usableArea(monitor: monitor.layoutFrame)
        let assignmentByID = Dictionary(
            assignments.map { ($0.windowID, $0) },
            uniquingKeysWith: { _, last in last }
        )
        // Structural columns (any slot) — not live-AX count. Switch-back must not fullscreen
        // Safari while WhatsApp/Discord are still deminiaturizing.
        let tileColumns = ws.columns.filter { !$0.windows.isEmpty }.count
        let monitorFrames = monitors.monitors.map(\.frame)
        let indices: [Int] = columnIndex.map { [$0] }
            ?? ws.columns.indices.filter { !ws.columns[$0].windows.isEmpty }
        var applied = 0

        suppressGeometryEnforce(for: 0.35)
        ax.withMutation {
            for colIndex in indices {
                var stackFrames: [(WindowID, Rect)] = []
                for wid in ws.columns[colIndex].windows {
                    guard var win = windowsByID[wid], !win.isIgnored else { continue }
                    guard authoritativeHome(for: wid) == workspaceID else { continue }
                    // Soft-missing: keep the slot, don't tessellate half-height against ghosts.
                    if missingScanCounts[wid] != nil { continue }
                    guard let a = assignmentByID[wid], a.visible else { continue }
                    if win.isFloating || win.isScratchpad {
                        floatingOverrides.remove(wid)
                        win.isFloating = false
                        win.isScratchpad = false
                        windowsByID[wid] = win
                    }
                    if ax.isMinimized(wid) { ax.setMinimized(false, id: wid) }
                    var frame = clampStackTileFrame(a.frame, usable: usable)
                    if tileColumns <= 1 {
                        frame.x = usable.x
                        frame.width = usable.width
                    } else {
                        frame = clampHorizontalTileFrame(frame, for: wid)
                    }
                    stackFrames.append((wid, frame))
                }
                stackFrames.sort { $0.1.y < $1.1.y }
                guard !stackFrames.isEmpty else { continue }

                if stackFrames.count >= 2 {
                    let colX = stackFrames[0].1.x
                    let colW = stackFrames[0].1.width
                    // Only retessellate when a tile overflows usable — otherwise keep
                    // computeFrames heights (leafWeights) so Electron stacks stay calm.
                    let overflows = stackFrames.contains {
                        $0.1.maxY > usable.maxY + 8 || $0.1.y < usable.y - 8
                    }
                    if overflows {
                        stackFrames = tessellateColumnStack(stackFrames, usable: usable, x: colX, width: colW)
                    } else {
                        // Still normalize x/width; leave y/height from the engine.
                        stackFrames = stackFrames.map { id, f in
                            (id, Rect(x: colX, y: f.y, width: colW, height: f.height))
                        }
                    }
                }

                let multiStack = stackFrames.count >= 2
                suppressGeometryEnforce(for: 0.55)
                for attempt in 0..<2 {
                    for (index, (wid, frame)) in stackFrames.enumerated() {
                        let positionFirst = multiStack && index > 0
                        ax.forceStackTileFrame(frame, id: wid, positionFirst: positionFirst)
                        if multiStack {
                            ax.forceStackTileFrame(frame, id: wid, positionFirst: !positionFirst)
                        }
                        if forceReveal || shouldForceTileExpand(workspaceID)
                            || !ax.isSettled(id: wid, frame: frame, monitors: monitorFrames) {
                            ax.reveal(frame: frame, id: wid)
                        }
                        lastFrames[wid] = frame
                        applied += 1
                    }
                    let overflow = stackFrames.contains { wid, frame in
                        guard let live = ax.currentFrame(of: wid) else { return true }
                        return live.maxY > usable.maxY + 8
                            || live.maxY > frame.maxY + 8
                            || live.height > frame.height + 80
                            || live.width > frame.width + 40
                    }
                    if !overflow { break }
                    _ = attempt
                }
            }
        }
        // Final clamp: Electron often expands a few dozen px past usable after deminiaturize.
        clampActiveTilesToUsable(workspaceID: workspaceID, monitor: monitor)
        tuckWindowsLeakingWrongMonitor(preferredMonitorFrame: monitor.layoutFrame, onlyOnMonitor: monitor)
        return applied
    }

    func clampActiveTilesToUsable(workspaceID: String, monitor: MonitorInfo) {
        guard let ws = workspaces.workspaces[workspaceID] else { return }
        let usable = engine.usableArea(monitor: monitor.layoutFrame)
        ax.withMutation {
            for wid in ws.columns.flatMap(\.windows) {
                guard let win = windowsByID[wid], win.isTiled, !win.isIgnored else { continue }
                guard authoritativeHome(for: wid) == workspaceID else { continue }
                guard let live = ax.currentFrame(of: wid) else { continue }
                guard live.maxY > usable.maxY + 8 || live.y < usable.y - 8 else { continue }
                let target: Rect = {
                    if let expected = lastFrames[wid], expected.maxY <= usable.maxY + 1 {
                        return clampStackTileFrame(expected, usable: usable)
                    }
                    return clampStackTileFrame(live, usable: usable)
                }()
                ax.forceFrame(target, id: wid)
                lastFrames[wid] = target
            }
        }
    }

    func needsElectronReflowNudge(_ win: ManagedWindow) -> Bool {
        let bundle = (win.bundleID ?? "").lowercased()
        let name = win.appName.lowercased()
        let hay = bundle.isEmpty ? name : bundle
        return hay.contains("whatsapp")
            || hay.contains("discord")
            || hay.contains("slack")
            || hay.contains("telegram")
            || hay.contains("element")
            || hay.contains("notion")
            || hay.contains("figma")
            || hay.contains("spotify")
            || hay.contains("chromium")
            || hay.contains("electron")
    }

    func nudgeElectronTileReflow(workspaceID: String) {
        guard let ws = workspaces.workspaces[workspaceID] else { return }
        let monitorFrames = monitors.monitors.map(\.frame)
        ax.withMutation {
            for wid in ws.columns.flatMap(\.windows) {
                guard let win = windowsByID[wid], win.isTiled, !win.isIgnored else { continue }
                guard needsElectronReflowNudge(win) else { continue }
                guard authoritativeHome(for: wid) == workspaceID else { continue }
                let frame = expectedTileFrame(for: wid)
                    ?? lastFrames[wid]
                    ?? ax.currentFrame(of: wid)
                guard let frame, frame.height > 96, frame.width > 160 else { continue }
                // Already on target — shrink/grow nudge only causes visible flicker.
                if !ax.isMinimized(wid),
                   ax.isSettled(id: wid, frame: frame, monitors: monitorFrames) {
                    continue
                }
                if ax.isMinimized(wid) {
                    ax.setMinimized(false, id: wid)
                }
                // Shrink both axes so Chromium must reflow, then restore the tile.
                var shrunk = frame
                shrunk.width = max(160, frame.width - 24)
                shrunk.height = max(96, frame.height - 24)
                ax.forceFrame(shrunk, id: wid)
                ax.forceFrame(frame, id: wid)
                lastFrames[wid] = frame
            }
        }
    }

    func scheduleElectronReflowPasses(workspaceID: String, generation: UInt64) {
        // Kept for call sites that still want Chromium help — prefer the lighter
        // `scheduleWorkspaceSwitchSettle` path for routine switches.
        guard workspaceNeedsElectronSettle(workspaceID) else { return }
        let delays: [UInt64] = [280_000_000, 750_000_000]
        for delay in delays {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard let self, self.workspaceSwitchGeneration == generation else { return }
                guard self.workspaces.activeWorkspaceByMonitor.values.contains(workspaceID) else { return }
                guard let mon = self.monitors.monitors.first(where: {
                    self.workspaces.activeWorkspaceByMonitor[$0.id] == workspaceID
                }) else { return }
                guard !self.workspaceTilesSettled(workspaceID: workspaceID, on: mon) else { return }
                self.clampActiveTilesToUsable(workspaceID: workspaceID, monitor: mon)
                self.nudgeElectronTileReflow(workspaceID: workspaceID)
                self.refreshBorder()
            }
        }
    }

    func applyStackColumnFrames(for id: WindowID) {
        if overlaysCaptureFocus { return }
        guard let home = authoritativeHome(for: id),
              var ws = workspaces.workspaces[home],
              let loc = engine.locate(id, in: ws) else { return }
        let mon = monitors.monitors.first(where: {
            workspaces.activeWorkspaceByMonitor[$0.id] == home
        }) ?? workspaces.preferredMonitor(forWorkspace: home, monitors: monitors.monitors)
            ?? primaryMonitor()
        guard let mon else { return }

        prepareWorkspaceLayoutForDisplay(home, monitor: mon)
        ws = workspaces.workspaces[home] ?? ws

        let assignments = engine.computeFrames(
            workspace: ws,
            windows: windowsByID,
            monitor: mon.layoutFrame,
            active: true,
            stackExcluded: stackExcludedFromLayout(),
            layoutExcluded: layoutExcludedWindowIDs(for: home, monitor: mon)
        )
        _ = applyWorkspaceColumnTileFrames(
            workspaceID: home,
            monitor: mon,
            assignments: assignments,
            forceReveal: true,
            columnIndex: loc.col
        )
    }

    func layoutExcludedWindowIDs(for wsID: String, monitor: MonitorInfo? = nil) -> Set<WindowID> {
        if let cached = layoutExcludedCache[wsID] {
            return cached
        }
        let wsActive = workspaces.activeWorkspaceByMonitor.values.contains(wsID)
        var excluded = Set<WindowID>()
        for (id, win) in windowsByID where win.isTiled {
            if let home = authoritativeHome(for: id), home != wsID {
                excluded.insert(id)
                continue
            }
            if wsActive, authoritativeHome(for: id) == wsID {
                continue
            }
            if missingScanCounts[id] != nil || cachedIsMinimized(id) {
                excluded.insert(id)
            }
        }
        layoutExcludedCache[wsID] = excluded
        return excluded
    }

    func cachedIsMinimized(_ id: WindowID) -> Bool {
        if let cached = minimizedCache[id] { return cached }
        let value = ax.isMinimized(id)
        minimizedCache[id] = value
        return value
    }

    func beginLayoutPass() {
        layoutExcludedCache.removeAll(keepingCapacity: true)
        minimizedCache.removeAll(keepingCapacity: true)
        structuralHealDoneThisPass = false
    }

    func runStructuralHealIfNeeded(reinsert: Bool = true) {
        if structuralHealDoneThisPass { return }
        structuralHealDoneThisPass = true
        healStaleColumnEntries()
        if reinsert {
            reinsertOrphanTiles()
        }
    }

    func syncTokenIndex() {
        tokenByWindowToken = Dictionary(uniqueKeysWithValues: windowsByID.keys.map { ($0.token, $0) })
    }

    func rebindAddedWindowIfTokenChurn(_ newID: WindowID) -> Bool {
        guard let win = windowsByID[newID], let bid = win.bundleID, !bid.isEmpty else { return false }
        let liveAX = Set(ax.currentWindows.map(\.id))
        guard liveAX.contains(newID) else { return false }
        let newTitle = Self.normalizedWindowTitle(win.title)
        for (wsID, ws) in workspaces.workspaces {
            for col in ws.columns {
                for stale in col.windows where stale != newID {
                    guard stale.pid == newID.pid,
                          windowsByID[stale]?.bundleID == bid else { continue }
                    let staleLive = liveAX.contains(stale)
                    let staleMissing = missingScanCounts[stale] != nil || !staleLive
                    guard staleMissing else { continue }
                    if !newTitle.isEmpty {
                        let staleTitle = Self.normalizedWindowTitle(windowsByID[stale]?.title ?? "")
                        if !staleTitle.isEmpty,
                           staleTitle != newTitle,
                           !Self.titlesLooselyMatch(newTitle, staleTitle) {
                            continue
                        }
                    }
                    rebindWindowIdentity(from: stale, to: newID, home: wsID)
                    if configStore.config.settings.developerMode {
                        NSLog("ALWM: rebind token %@ → %@ ws=%@", stale.token, newID.token, wsID)
                    }
                    return true
                }
            }
        }
        return false
    }

    func rebindWindowIdentity(from stale: WindowID, to live: WindowID, home: String) {
        guard stale != live else { return }
        for (_, var ws) in workspaces.workspaces {
            var changed = false
            for colIdx in ws.columns.indices {
                if let row = ws.columns[colIdx].windows.firstIndex(of: stale) {
                    ws.columns[colIdx].windows[row] = live
                    changed = true
                }
            }
            if changed {
                if let weight = ws.leafWeights.removeValue(forKey: stale.token) {
                    ws.leafWeights[live.token] = weight
                }
                if let loc = engine.locate(live, in: ws) {
                    ws.focusedColumn = loc.col
                    ws.focusedWindowInColumn[loc.col] = loc.row
                }
                workspaces.setWorkspace(ws)
            }
        }
        windowWorkspace[live] = windowWorkspace[stale] ?? home
        windowWorkspace.removeValue(forKey: stale)
        runtimeState.setAssignment(home, for: live)
        runtimeState.setAssignment(nil, for: stale)
        missingScanCounts.removeValue(forKey: stale)
        missingScanCounts.removeValue(forKey: live)
        savedFrames.removeValue(forKey: stale)
        lastFrames.removeValue(forKey: stale)
        forcedTiledUntil[live] = Date().addingTimeInterval(8.0)
        forcedTiledUntil.removeValue(forKey: stale)
        floatingOverrides.remove(stale)
        windowsByID.removeValue(forKey: stale)
        tokenByWindowToken.removeValue(forKey: stale.token)
        tokenByWindowToken[live.token] = live
        if var tracked = windowsByID[live] {
            tracked.isFloating = false
            windowsByID[live] = tracked
        }
    }

    func visibilitySignature(
        activeIDs: Set<String>,
        visibleIDs: Set<WindowID>,
        target: [WindowID: Rect]
    ) -> String {
        let actives = activeIDs.sorted().joined(separator: "+")
        let vis = visibleIDs.map(\.token).sorted().joined(separator: ",")
        let frames = visibleIDs.sorted(by: { $0.token < $1.token }).compactMap { id -> String? in
            guard let f = target[id] else { return nil }
            return "\(id.token):\(Int(f.x)),\(Int(f.y)),\(Int(f.width)),\(Int(f.height))"
        }.joined(separator: "|")
        return "\(actives)|\(vis)|\(frames)"
    }

    func clampHorizontalTileFrame(_ frame: Rect, for id: WindowID) -> Rect {
        guard let home = authoritativeHome(for: id) else { return frame }
        let mon = displayMonitor(
            forHome: home,
            fallback: primaryMonitor() ?? monitors.monitors[0]
        )
        let usable = engine.usableArea(monitor: mon.layoutFrame)
        return clampStackTileFrame(frame, usable: usable)
    }

    func enforceActiveTileFrames() {
        if overlaysCaptureFocus { return }
        let activeIDs = Set(workspaces.activeWorkspaceByMonitor.values)
        guard !activeIDs.isEmpty else { return }
        let monitorFrames = monitors.monitors.map(\.frame)
        let stackExcluded = stackExcludedFromLayout()

        ax.withMutation {
            for wsID in activeIDs {
                guard let ws = workspaces.workspaces[wsID] else { continue }
                let mon = monitors.monitors.first(where: {
                    workspaces.activeWorkspaceByMonitor[$0.id] == wsID
                }) ?? workspaces.preferredMonitor(forWorkspace: wsID, monitors: monitors.monitors)
                    ?? primaryMonitor()
                guard let mon else { continue }

                let assignments = engine.computeFrames(
                    workspace: ws,
                    windows: windowsByID,
                    monitor: mon.layoutFrame,
                    active: true,
                    stackExcluded: stackExcluded,
                    layoutExcluded: layoutExcludedWindowIDs(for: wsID, monitor: mon)
                )
                for a in assignments where a.visible {
                    guard let win = windowsByID[a.windowID], !win.isIgnored else { continue }
                    guard win.isTiled || workspaces.workspaceID(containing: a.windowID) != nil else { continue }
                    guard authoritativeHome(for: a.windowID) == wsID else { continue }
                    if let live = liveFrameForVisibility(a.windowID),
                       frameLeaksWrongMonitor(home: wsID, frame: live) {
                        continue
                    }
                    guard OffscreenParking.isOnAnyMonitor(a.frame, monitors: monitorFrames) else { continue }
                    var target = a.frame
                    if shouldForceTileExpand(wsID), ws.columns.filter({ !$0.windows.isEmpty }).count <= 1 {
                        target.x = engine.usableArea(monitor: mon.layoutFrame).x
                        target.width = engine.usableArea(monitor: mon.layoutFrame).width
                    }
                    let usable = engine.usableArea(monitor: mon.layoutFrame)
                    target = clampStackTileFrame(target, usable: usable)
                    ax.reveal(frame: target, id: a.windowID)
                    if shouldForceTileExpand(wsID)
                        || !ax.isSettled(id: a.windowID, frame: target, monitors: monitorFrames) {
                        ax.applyFrameOnly(frame: target, to: a.windowID)
                    }
                    if let live = ax.currentFrame(of: a.windowID), live.maxY > usable.maxY + 8 {
                        ax.forceFrame(target, id: a.windowID)
                    }
                    // Prefer engine target — storing Electron's overflowed live hid the composer.
                    lastFrames[a.windowID] = target
                }
            }
        }
        tuckWindowsLeakingWrongMonitor()
    }

    func scheduleTileFrameEnforcement(stackAnchor: WindowID? = nil) {
        if overlaysCaptureFocus { return }
        if stackAnchor != nil {
            suppressGeometryEnforce(for: 0.45)
        }
        if let stackAnchor {
            applyStackColumnFrames(for: stackAnchor)
        } else {
            enforceActiveTileFrames()
            applyAllActiveStackColumns()
            tuckWindowsLeakingWrongMonitor()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, !self.overlaysCaptureFocus else { return }
            if let stackAnchor {
                self.applyStackColumnFrames(for: stackAnchor)
            } else {
                self.enforceActiveTileFrames()
                self.applyAllActiveStackColumns()
                self.tuckWindowsLeakingWrongMonitor()
            }
        }
    }

    func prepareWorkspaceLayoutForDisplay(_ wsID: String, monitor: MonitorInfo) {
        guard var ws = workspaces.workspaces[wsID] else { return }
        let before = ws
        syncColumnWidthsToUsable(workspace: &ws, workspaceID: wsID)
        if ws != before {
            workspaces.setWorkspace(ws)
        }
    }

    func stripLeadingVacantColumns(wsID: String, layoutExcluded: Set<WindowID>) {
        guard var ws = workspaces.workspaces[wsID] else { return }
        var changed = false
        while let first = ws.columns.first, first.windows.isEmpty {
            ws.columns.removeFirst()
            changed = true
        }
        if changed {
            ws.viewOffset = 0
            ws.focusedColumn = min(max(0, ws.focusedColumn), max(0, ws.columns.count - 1))
            workspaces.setWorkspace(ws)
        }
    }

    func pruneVacantColumnSlots(wsID: String) {
        guard var ws = workspaces.workspaces[wsID] else { return }
        let before = ws.columns.count
        ws.columns.removeAll { $0.windows.isEmpty }
        guard ws.columns.count != before else { return }
        ws.focusedColumn = min(max(0, ws.focusedColumn), max(0, ws.columns.count - 1))
        workspaces.setWorkspace(ws)
    }

    func prepareAllActiveWorkspaceLayouts() {
        for mon in monitors.monitors {
            guard let wsID = workspaces.activeWorkspaceByMonitor[mon.id] else { continue }
            prepareWorkspaceLayoutForDisplay(wsID, monitor: mon)
        }
    }

    func applyFluidLayout(animated: Bool, onlyMonitor: MonitorInfo? = nil) {
        if isApplyingVisibility {
            pendingVisibilityAnimated = (pendingVisibilityAnimated ?? true) && animated
            return
        }
        if overlaysCaptureFocus {
            refreshChrome()
            return
        }
        guard let layoutMonitor = primaryMonitor() ?? monitors.monitors.first else { return }
        beginLayoutPass()
        animator.stop(finish: true)
        syncColumnTilesNotFloat()
        retileAccidentalFloats(forceClearOverrides: false)
        // Tile move just persisted columns — heal/reinsert here races and re-splits stacks.
        if Date() >= suppressIngestReassignUntil {
            runStructuralHealIfNeeded()
        } else {
            let stripped = ejectWindowsListedOutsideStickyHome()
            if !stripped.isEmpty, configStore.config.settings.developerMode {
                NSLog("ALWM: ejected cross-workspace column leaks: %@", stripped.sorted().joined(separator: ","))
            }
        }

        let scopedWSID = onlyMonitor.flatMap { workspaces.activeWorkspaceByMonitor[$0.id] }
        let activeIDs: Set<String> = if let scopedWSID {
            [scopedWSID]
        } else {
            Set(workspaces.activeWorkspaceByMonitor.values)
        }
        let allMonitorFrames = monitors.monitors.map(\.frame)
        let stackExcluded = stackExcludedFromLayout()
        var frames: [WindowID: Rect] = [:]
        var onScreenIDs: Set<WindowID> = []

        for (wsID, ws) in workspaces.workspaces {
            if onlyMonitor != nil, wsID != scopedWSID { continue }
            let active = activeIDs.contains(wsID)
            let monitorForWS: MonitorInfo = {
                if let mon = monitors.monitors.first(where: { workspaces.activeWorkspaceByMonitor[$0.id] == wsID }) {
                    return mon
                }
                if let preferred = workspaces.preferredMonitor(forWorkspace: wsID, monitors: monitors.monitors) {
                    return preferred
                }
                return layoutMonitor
            }()
            var layoutWS = ws
            if active {
                prepareWorkspaceLayoutForDisplay(wsID, monitor: monitorForWS)
                layoutWS = workspaces.workspaces[wsID] ?? ws
            }
            let layoutExcluded = layoutExcludedWindowIDs(for: wsID, monitor: monitorForWS)
            let assignments = engine.computeFrames(
                workspace: layoutWS,
                windows: windowsByID,
                monitor: monitorForWS.layoutFrame,
                active: active,
                stackExcluded: stackExcluded,
                layoutExcluded: layoutExcluded
            )
            for a in assignments {
                // Stale column membership: skip — heal/reinsert handles it.
                // Never overwrite a correct home frame already recorded for this id.
                if let home = authoritativeHome(for: a.windowID), home != wsID { continue }
                frames[a.windowID] = a.frame
                if active {
                    let usable = OffscreenParking.isUsableOnscreenFrame(a.frame, monitors: allMonitorFrames)
                    if usable { onScreenIDs.insert(a.windowID) }
                }
            }
        }

        // Quake: keep docked float geometry without visibility thrash.
        if let qid = quake.windowID {
            let mon = monitors.monitors.first(where: { $0.id == primaryMonitorID })
                ?? primaryMonitor()
                ?? monitors.monitors.first
            if let mon {
                let qFrame = quake.isVisible
                    ? quake.visibleFrame(settings: configStore.config.settings.quake, monitor: mon)
                    : quake.hiddenFrame(settings: configStore.config.settings.quake, monitor: mon)
                frames[qid] = qFrame
                if quake.isVisible { onScreenIDs.insert(qid) }
            }
        }

        ax.withMutation {
            for (id, frame) in frames {
                guard let win = windowsByID[id], !win.isIgnored else { continue }
                if let scopedWSID, id != quake.windowID, authoritativeHome(for: id) != scopedWSID {
                    continue
                }
                let homeActive = authoritativeHome(for: id).map { isHomeActiveOnAnyMonitor($0) } ?? false
                if id == quake.windowID {
                    if quake.isVisible {
                        ax.setMinimized(false, id: id)
                        ax.applyFrameOnly(frame: frame, to: id)
                    } else {
                        // Minimize + below-arrangement park — never edge-slide (macOS clamps
                        // a thin strip onto the display during workspace switches).
                        ax.parkAndHide(frame: frame, id: id, monitors: allMonitorFrames)
                    }
                    lastFrames[id] = frame
                    continue
                }
                let inColumn = workspaces.workspaceID(containing: id) != nil
                if homeActive || onScreenIDs.contains(id) {
                    if (win.isTiled || inColumn), homeActive {
                        if ax.isMinimized(id) {
                            ax.setMinimized(false, id: id)
                        }
                        let target = clampHorizontalTileFrame(frame, for: id)
                        if ax.isSettled(id: id, frame: target, monitors: allMonitorFrames) {
                            lastFrames[id] = ax.currentFrame(of: id) ?? target
                            continue
                        }
                        ax.reveal(frame: target, id: id)
                        lastFrames[id] = ax.currentFrame(of: id) ?? target
                    } else if win.isTiled || inColumn {
                        if onScreenIDs.contains(id) {
                            if ax.isMinimized(id) {
                                ax.setMinimized(false, id: id)
                            }
                            ax.applyFrameOnly(frame: frame, to: id)
                            lastFrames[id] = ax.currentFrame(of: id) ?? frame
                        } else {
                            ax.parkOffscreen(frame: frame, id: id, monitors: allMonitorFrames)
                            lastFrames[id] = ax.currentFrame(of: id)
                                ?? ax.currentParkedFrame(of: id, sizeFrom: frame, monitors: allMonitorFrames)
                        }
                    } else if onScreenIDs.contains(id) {
                        if ax.isMinimized(id) {
                            ax.setMinimized(false, id: id)
                        }
                        ax.applyFrameOnly(frame: frame, to: id)
                        lastFrames[id] = frame
                    } else if let home = authoritativeHome(for: id),
                              let live = ax.currentFrame(of: id),
                              frameLeaksWrongMonitor(home: home, frame: live) {
                        ax.parkOffscreen(frame: frame, id: id, monitors: allMonitorFrames)
                        lastFrames[id] = ax.currentFrame(of: id)
                            ?? ax.currentParkedFrame(of: id, sizeFrom: frame, monitors: allMonitorFrames)
                    } else if OffscreenParking.isUsableOnscreenFrame(frame, monitors: allMonitorFrames) {
                        ax.parkOffscreen(frame: frame, id: id, monitors: allMonitorFrames)
                        lastFrames[id] = ax.currentFrame(of: id)
                            ?? ax.currentParkedFrame(of: id, sizeFrom: frame, monitors: allMonitorFrames)
                    }
                } else {
                    // Inactive workspace: leave minimized windows alone; only fix leaks.
                    if ax.isMinimized(id) {
                        ax.reparkIfLeaking(id: id, monitors: allMonitorFrames, allowMinimize: false)
                    } else if let live = ax.currentFrame(of: id),
                              !OffscreenParking.isUsableOnscreenFrame(live, monitors: allMonitorFrames),
                              !OffscreenParking.intersectsAnyMonitor(live, monitors: allMonitorFrames) {
                        lastFrames[id] = live
                    } else {
                        ax.parkOffscreen(frame: frame, id: id, monitors: allMonitorFrames)
                        lastFrames[id] = ax.currentFrame(of: id)
                            ?? ax.currentParkedFrame(of: id, sizeFrom: frame, monitors: allMonitorFrames)
                    }
                }
            }
        }
        if let scopedWSID, let ws = workspaces.workspaces[scopedWSID] {
            for col in ws.columns {
                let tiled = col.windows.filter { id in
                    guard let w = windowsByID[id] else { return false }
                    return !w.isIgnored
                }
                guard tiled.count >= 2, let anchor = tiled.first else { continue }
                applyStackColumnFrames(for: anchor)
            }
        } else if !overlaysCaptureFocus {
            tuckWindowsLeakingWrongMonitor(preferredMonitorFrame: layoutMonitor.frame)
            ax.suppressNotifications(for: 0.2)
            applyAllActiveStackColumns()
            tuckWindowsLeakingWrongMonitor(preferredMonitorFrame: layoutMonitor.frame)
        } else {
            ax.suppressNotifications(for: 0.2)
        }
        refreshBorder()
        refreshChrome()

        if let pending = pendingVisibilityAnimated {
            pendingVisibilityAnimated = nil
            DispatchQueue.main.async { [weak self] in
                self?.applyWorkspaceVisibility(animated: pending)
            }
        }
    }

    func authoritativeHome(for id: WindowID) -> String? {
        if let sticky = windowWorkspace[id] { return sticky }
        if let saved = runtimeState.assignment(for: id),
           workspaces.workspaces[saved] != nil {
            return saved
        }
        return workspaces.workspaceID(containing: id)
    }

    func displayMonitor(forHome home: String, fallback: MonitorInfo) -> MonitorInfo {
        monitors.monitors.first { workspaces.activeWorkspaceByMonitor[$0.id] == home }
            ?? workspaces.preferredMonitor(forWorkspace: home, monitors: monitors.monitors)
            ?? fallback
    }

    func isHomeActiveOnAnyMonitor(_ home: String) -> Bool {
        workspaces.activeWorkspaceByMonitor.values.contains(home)
    }

    func frameLeaksWrongMonitor(home: String, frame: Rect) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let monitorFrames = monitors.monitors.map(\.frame)
        guard OffscreenParking.intersectsAnyMonitor(frame, monitors: monitorFrames) else { return false }

        if OffscreenParking.isEdgeStrip(frame, monitors: monitorFrames) {
            for mon in monitors.monitors {
                guard OffscreenParking.intersectsAnyMonitor(frame, monitors: [mon.frame]) else { continue }
                if workspaces.activeWorkspaceByMonitor[mon.id] != home { return true }
            }
            return false
        }

        if let mon = monitors.monitorContaining(pointX: frame.midX, pointY: frame.midY),
           workspaces.activeWorkspaceByMonitor[mon.id] != home {
            return true
        }

        // Safari/Electron can keep the midpoint on the home monitor while drawing on another display.
        for mon in monitors.monitors {
            guard workspaces.activeWorkspaceByMonitor[mon.id] != home else { continue }
            let ix0 = max(frame.x, mon.frame.x)
            let iy0 = max(frame.y, mon.frame.y)
            let ix1 = min(frame.maxX, mon.frame.maxX)
            let iy1 = min(frame.maxY, mon.frame.maxY)
            if ix1 > ix0, iy1 > iy0, (ix1 - ix0) * (iy1 - iy0) >= 64 {
                return true
            }
        }
        return false
    }

    func liveFrameForVisibility(_ id: WindowID) -> Rect? {
        ax.rawFrame(of: id) ?? ax.currentFrame(of: id)
    }

    func samePidHasActiveSibling(_ id: WindowID) -> Bool {
        for other in windowsByID.keys where other.pid == id.pid && other != id {
            if let oh = authoritativeHome(for: other), isHomeActiveOnAnyMonitor(oh) {
                return true
            }
        }
        return false
    }

    func allowsPerWindowMinimize(_ id: WindowID) -> Bool {
        let bid = (windowsByID[id]?.bundleID ?? "").lowercased()
        let name = (windowsByID[id]?.appName ?? "").lowercased()
        let hay = bid.isEmpty ? name : bid
        if hay.isEmpty { return true }
        // Chromium shells: minimize corrupts webview chrome (WhatsApp composer vanishes).
        if hay.contains("electron") { return false }
        if hay.contains("whatsapp") { return false }
        if hay.contains("telegram") { return false }
        if hay.hasPrefix("com.microsoft.vscode") || hay.hasPrefix("com.visualstudio.code") { return false }
        if hay.hasPrefix("com.github.atom") { return false }
        if hay.hasPrefix("com.slack.") || hay.hasPrefix("com.tinyspeck.") { return false }
        if hay.hasPrefix("com.hnc.discord") || hay.hasPrefix("com.discordapp") { return false }
        if hay.hasPrefix("com.figma.") { return false }
        if hay.hasPrefix("com.spotify.") { return false }
        if hay.contains("notion") { return false }
        return true
    }

    func allowMinimizeDespiteSibling(_ id: WindowID) -> Bool {
        !samePidHasActiveSibling(id) || allowsPerWindowMinimize(id)
    }

    func isActiveHomeTile(_ id: WindowID) -> Bool {
        guard let win = windowsByID[id], win.isTiled, !win.isIgnored else { return false }
        guard let home = authoritativeHome(for: id), isHomeActiveOnAnyMonitor(home) else { return false }
        return workspaces.workspaceID(containing: id) == home
    }

    func hideOutgoingWindow(_ id: WindowID, frame: Rect, allMonitorFrames: [Rect]) {
        if isVisibilityRevealProtected(id) { return }
        if isActiveHomeTile(id) { return }
        if id == quake.windowID {
            ax.parkAndHide(frame: frame, id: id, monitors: allMonitorFrames)
            lastFrames[id] = frame
            return
        }
        if ax.isMinimized(id) {
            ax.reparkIfLeaking(id: id, monitors: allMonitorFrames, allowMinimize: false)
            lastFrames[id] = frame
            return
        }
        if let live = ax.currentFrame(of: id),
           OffscreenParking.isUsableOnscreenFrame(live, monitors: allMonitorFrames) {
            savedFrames[id] = live
        } else if let prev = lastFrames[id],
                  OffscreenParking.isUsableOnscreenFrame(prev, monitors: allMonitorFrames) {
            savedFrames[id] = prev
        }
        var parkFrame = frame
        if let saved = savedFrames[id] {
            parkFrame.width = saved.width
            parkFrame.height = saved.height
        }
        // Park off-screen first; escalate to per-window minimize if Safari clamps back.
        ax.parkOffscreen(frame: parkFrame, id: id, monitors: allMonitorFrames)
        if let home = authoritativeHome(for: id),
           let live = liveFrameForVisibility(id),
           frameLeaksWrongMonitor(home: home, frame: live) {
            ax.reparkIfLeaking(
                id: id,
                monitors: allMonitorFrames,
                allowMinimize: allowMinimizeDespiteSibling(id)
            )
            if let still = liveFrameForVisibility(id),
               frameLeaksWrongMonitor(home: home, frame: still),
               allowsPerWindowMinimize(id) {
                ax.parkAndHide(frame: parkFrame, id: id, monitors: allMonitorFrames)
            }
        }
    }

    func reparkSamePidEdgeLeaks(on monitors: [Rect]) {
        tuckWindowsLeakingWrongMonitor(preferredMonitorFrame: monitors.first)
    }

    func tuckWindowsLeakingWrongMonitor(preferredMonitorFrame: Rect? = nil, onlyOnMonitor: MonitorInfo? = nil) {
        let allMonitorFrames = monitors.monitors.map(\.frame)
        guard !allMonitorFrames.isEmpty else { return }
        let preferred = preferredMonitorFrame ?? onlyOnMonitor?.frame ?? primaryMonitor()?.frame ?? allMonitorFrames[0]
        let park = OffscreenParking.parkOrigin(monitors: allMonitorFrames, preferred: preferred)

        ax.withMutation {
            for (id, win) in windowsByID where !win.isIgnored && id != quake.windowID {
                if isVisibilityRevealProtected(id) { continue }
                if isActiveHomeTile(id) { continue }
                guard let home = authoritativeHome(for: id) else { continue }
                guard let live = liveFrameForVisibility(id) else { continue }
                guard frameLeaksWrongMonitor(home: home, frame: live) else { continue }
                if let onlyOnMonitor {
                    guard OffscreenParking.intersectsAnyMonitor(live, monitors: [onlyOnMonitor.frame]) else {
                        continue
                    }
                }

                let siblingOnActive = samePidHasActiveSibling(id)
                ax.reparkIfLeaking(
                    id: id,
                    monitors: allMonitorFrames,
                    allowMinimize: !siblingOnActive || allowsPerWindowMinimize(id)
                )
                if ax.isMinimized(id) { continue }

                var parkFrame = savedFrames[id] ?? live
                parkFrame.x = park.x
                parkFrame.y = park.y
                ax.parkOffscreen(frame: parkFrame, id: id, monitors: allMonitorFrames)
                if let after = liveFrameForVisibility(id),
                   frameLeaksWrongMonitor(home: home, frame: after),
                   allowsPerWindowMinimize(id) {
                    ax.parkAndHide(frame: parkFrame, id: id, monitors: allMonitorFrames)
                }
                lastFrames[id] = ax.currentFrame(of: id)
                    ?? ax.currentParkedFrame(of: id, sizeFrom: parkFrame, monitors: allMonitorFrames)
            }
        }
    }

    func frameIsOnMonitorShowingHome(home: String, frame: Rect) -> Bool {
        let monitorFrames = monitors.monitors.map(\.frame)
        guard OffscreenParking.isUsableOnscreenFrame(frame, monitors: monitorFrames) else { return false }
        guard let mon = monitors.monitorContaining(pointX: frame.midX, pointY: frame.midY) else { return false }
        return workspaces.activeWorkspaceByMonitor[mon.id] == home
    }

    func floatFrameForActiveHome(
        id: WindowID,
        home: String,
        live: Rect,
        layoutMonitor: MonitorInfo
    ) -> Rect {
        if frameIsOnMonitorShowingHome(home: home, frame: live) {
            return live
        }
        if let saved = savedFrames[id],
           frameIsOnMonitorShowingHome(home: home, frame: saved) {
            return saved
        }
        let mon = displayMonitor(forHome: home, fallback: layoutMonitor)
        let usable = engine.usableArea(monitor: mon.layoutFrame)
        return Rect(
            x: usable.midX - min(live.width, usable.width) / 2,
            y: usable.midY - min(live.height, usable.height) / 2,
            width: min(max(live.width, 320), usable.width),
            height: min(max(live.height, 240), usable.height)
        )
    }

    func ejectWindowsListedOutsideStickyHome() -> Set<String> {
        var structurallyChanged: Set<String> = []
        for (wsID, var ws) in workspaces.workspaces {
            let colCountBefore = ws.columns.count
            var wsChanged = false
            for colIdx in ws.columns.indices {
                let before = ws.columns[colIdx].windows.count
                ws.columns[colIdx].windows.removeAll { id in
                    if let home = authoritativeHome(for: id) {
                        return home != wsID
                    }
                    let sticky = windowWorkspace[id] ?? runtimeState.assignment(for: id)
                    return sticky != nil && sticky != wsID
                }
                if ws.columns[colIdx].windows.count != before { wsChanged = true }
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

    func healStaleColumnEntries() {
        var changed = false
        var structurallyChanged = healBundleTokenChurn()
        structurallyChanged.formUnion(ejectWindowsListedOutsideStickyHome())
        let rules = configStore.config.rules
        let liveAX = Set(ax.currentWindows.map(\.id))

        for (wsID, var ws) in workspaces.workspaces {
            var wsChanged = false
            let colCountBefore = ws.columns.count
            for colIdx in ws.columns.indices {
                let before = ws.columns[colIdx].windows
                ws.columns[colIdx].windows.removeAll { id in
                    if let win = windowsByID[id],
                       AppRules.forcesFloat(rules: rules, window: win) {
                        return true
                    }
                    if isMoveProtectedTile(id) { return false }
                    // After sleep AX blips look like closed windows — keep slots until recovery ends.
                    if isResumeRecovering || Date() < resumeRecoveryEligibleUntil {
                        if let home = authoritativeHome(for: id), home != wsID { return true }
                        return false
                    }
                    if !liveAX.contains(id), missingScanCounts[id] != nil {
                        return true
                    }
                    if let count = missingScanCounts[id], shouldEjectMissingFromColumns(id, missingCount: count) {
                        return true
                    }
                    if windowsByID[id] == nil {
                        return true
                    }
                    if let home = authoritativeHome(for: id), home != wsID { return true }
                    return false
                }
                if ws.columns[colIdx].windows != before { wsChanged = true }
            }
            ws.columns.removeAll { col in
                col.windows.isEmpty
                    || col.windows.allSatisfy { id in
                        !liveAX.contains(id) && (missingScanCounts[id] ?? 0) >= 1
                    }
            }
            if ws.columns.count != colCountBefore {
                wsChanged = true
            }
            if wsChanged {
                if ws.focusedColumn >= ws.columns.count {
                    ws.focusedColumn = max(0, ws.columns.count - 1)
                }
                syncColumnWidthsToUsable(workspace: &ws, workspaceID: wsID)
                workspaces.setWorkspace(ws)
                changed = true
                if ws.columns.count != colCountBefore {
                    structurallyChanged.insert(wsID)
                }
            }
        }

        // Same window must never occupy two workspace column lists (bar + visibility leak).
        var listedIn: [WindowID: [String]] = [:]
        for (wsID, ws) in workspaces.workspaces {
            for col in ws.columns {
                for id in col.windows {
                    listedIn[id, default: []].append(wsID)
                }
            }
        }
        for (id, holders) in listedIn where Set(holders).count > 1 {
            let keep = windowWorkspace[id]
                ?? runtimeState.assignment(for: id)
                ?? authoritativeHome(for: id)
                ?? holders.sorted().first!
            for wsID in Set(holders) where wsID != keep {
                guard var ws = workspaces.workspaces[wsID] else { continue }
                var wsChanged = false
                for colIdx in ws.columns.indices {
                    let before = ws.columns[colIdx].windows.count
                    ws.columns[colIdx].windows.removeAll { $0 == id }
                    if ws.columns[colIdx].windows.count != before { wsChanged = true }
                }
                if wsChanged {
                    ws.columns.removeAll { $0.windows.isEmpty }
                    workspaces.setWorkspace(ws)
                    changed = true
                }
            }
        }

        if changed, configStore.config.settings.developerMode {
            NSLog("ALWM: healed stale column entries")
        }
        for wsID in structurallyChanged where isHomeActiveOnAnyMonitor(wsID) {
            guard let ws = workspaces.workspaces[wsID], !ws.columns.isEmpty else { continue }
            let sig = "\(ws.columns.count):\(structuralSnapSignature(for: ws))"
            if lastSnapSignature[wsID] == sig { continue }
            scheduleRebalanceWorkspace(wsID)
        }
    }

    func reinsertOrphanTiles() {
        if Date() < suppressIngestReassignUntil { return }
        let monitorFrames = monitors.monitors.map(\.frame)
        for (id, win) in windowsByID {
            guard !win.isIgnored, quake.windowID != id, !isQuakeOwned(id) else { continue }
            if AppRules.forcesFloat(rules: configStore.config.rules, window: win) { continue }
            if workspaces.workspaceID(containing: id) != nil { continue }
            if let win = windowsByID[id], let bid = win.bundleID, !bid.isEmpty {
                let siblings = windowsByID.values.filter {
                    $0.bundleID == bid && $0.id.pid == id.pid && $0.id != id
                }
                if !siblings.isEmpty,
                   let keeper = preferredBundleInstanceToken(
                       among: siblings.map(\.id) + [id], bundleID: bid
                   ),
                   keeper != id {
                    continue
                }
            }
            let forced = forcedTiledUntil[id].map { Date() < $0 } ?? false
            guard win.isTiled || forced else { continue }
            if cachedIsMinimized(id) { continue }
            let mon = monitors.monitorContaining(pointX: win.frame.midX, pointY: win.frame.midY)
                ?? primaryMonitor()
                ?? monitors.monitors.first
            guard let mon else { continue }
            let home = authoritativeHome(for: id) ?? resolveTargetWorkspace(for: win, on: mon)
            guard let home, workspaces.workspaces[home] != nil else { continue }
            let homeActive = isHomeActiveOnAnyMonitor(home)
            if !homeActive,
               let frame = lastFrames[id] ?? ax.currentFrame(of: id),
               !OffscreenParking.isUsableOnscreenFrame(frame, monitors: monitorFrames) {
                continue
            }
            let placeOn = workspaces.preferredMonitor(forWorkspace: home, monitors: monitors.monitors)
                ?? monitors.monitors.first(where: { workspaces.activeWorkspaceByMonitor[$0.id] == home })
                ?? mon
            let usable = engine.usableArea(monitor: placeOn.layoutFrame)
            if placeWindowFromSnapshot(id, into: home, usable: usable)
                || placeWindowInSavedColumn(id, into: home, usable: usable) {
                windowWorkspace[id] = home
                runtimeState.setAssignment(home, for: id)
            } else {
                let asNewCol = !(workspaces.workspaces[home]?.columns.isEmpty ?? true)
                assignWindow(id, to: home, on: placeOn, forceInsert: true, asNewColumn: asNewCol)
            }
            if configStore.config.settings.developerMode {
                NSLog("ALWM: reinserted orphan tile %@ → workspace %@", id.token, home)
            }
        }
    }

    func applyWorkspaceVisibility(animated: Bool) {
        if overlaysCaptureFocus {
            visibilityDeferredWhileOverlay = true
            return
        }
        if isApplyingVisibility {
            // Never drop a layout pass — coalesce into one follow-up after the in-flight apply.
            // Prefer sync if any request asked for it (structural heal wins over animation).
            pendingVisibilityAnimated = (pendingVisibilityAnimated ?? true) && animated
            return
        }
        isApplyingVisibility = true
        beginLayoutPass()
        visibilityApplyGeneration &+= 1
        let applyGeneration = visibilityApplyGeneration
        // Snap any in-flight lerp to its destination before computing a new target set.
        animator.stop(finish: true)
        let floatStripped = enforceAppRuleFloats()
        retileAccidentalFloats(forceClearOverrides: false)
        runStructuralHealIfNeeded()
        for wsID in floatStripped where isHomeActiveOnAnyMonitor(wsID) {
            if let mon = monitorForWorkspaceLayout(wsID) {
                prepareWorkspaceLayoutForDisplay(wsID, monitor: mon)
            }
        }
        defer {
            isApplyingVisibility = false
            visibilityForceReveal = false
            if let pending = pendingVisibilityAnimated {
                pendingVisibilityAnimated = nil
                DispatchQueue.main.async { [weak self] in
                    self?.applyWorkspaceVisibility(animated: pending)
                }
            }
        }

        var target: [WindowID: Rect] = [:]
        var visibleIDs: Set<WindowID> = []
        let activeIDs = Set(workspaces.activeWorkspaceByMonitor.values)
        let layoutMonitor = primaryMonitor()
        guard let layoutMonitor else { return }
        let allMonitorFrames = monitors.monitors.map(\.frame)
        let park = OffscreenParking.parkOrigin(monitors: allMonitorFrames, preferred: layoutMonitor.frame)
        let stackExcluded = stackExcludedFromLayout()

        for (wsID, ws) in workspaces.workspaces {
            let active = activeIDs.contains(wsID)
            let monitorForWS: MonitorInfo = {
                if let mon = monitors.monitors.first(where: { workspaces.activeWorkspaceByMonitor[$0.id] == wsID }) {
                    return mon
                }
                if let preferred = workspaces.preferredMonitor(forWorkspace: wsID, monitors: monitors.monitors) {
                    return preferred
                }
                return layoutMonitor
            }()
            var layoutWS = ws
            if active {
                prepareWorkspaceLayoutForDisplay(wsID, monitor: monitorForWS)
                layoutWS = workspaces.workspaces[wsID] ?? ws
            }
            var assignments = engine.computeFrames(
                workspace: layoutWS,
                windows: windowsByID,
                monitor: monitorForWS.layoutFrame,
                active: active,
                stackExcluded: stackExcluded,
                layoutExcluded: layoutExcludedWindowIDs(for: wsID, monitor: monitorForWS)
            )
            if !active {
                for (index, a) in assignments.enumerated() {
                    var copy = a
                    copy.frame.x = park.x - Double(index) * 40
                    copy.frame.y = park.y
                    copy.visible = false
                    assignments[index] = copy
                }
            } else {
                for (index, a) in assignments.enumerated() {
                    guard let home = authoritativeHome(for: a.windowID), home != wsID else { continue }
                    var copy = a
                    copy.frame.x = park.x - Double(index) * 40
                    copy.frame.y = park.y
                    copy.visible = false
                    assignments[index] = copy
                }
            }
            for a in assignments {
                target[a.windowID] = a.frame
                if a.visible { visibleIDs.insert(a.windowID) }
            }
        }

        // Sticky map wins: any tiled window not in an active workspace must be hidden.
        var needsOrphanRelayout = false
        for (id, win) in windowsByID where win.isTiled {
            let home = authoritativeHome(for: id)
            let onActive = home.map { isHomeActiveOnAnyMonitor($0) } ?? false
            if !onActive {
                visibleIDs.remove(id)
                if target[id] == nil {
                    target[id] = Rect(x: park.x, y: park.y, width: 800, height: 600)
                } else {
                    var f = target[id]!
                    f.x = park.x
                    f.y = park.y
                    target[id] = f
                }
            } else if target[id] == nil {
                let inSettleGrace = Date().timeIntervalSince(windowFirstTrackedAt[id] ?? .distantPast) < newWindowColumnGrace
                if inSettleGrace, let home {
                    let mon = monitors.monitors.first(where: {
                        workspaces.activeWorkspaceByMonitor[$0.id] == home
                    }) ?? layoutMonitor
                    assignWindow(id, to: home, on: mon)
                    prepareWorkspaceLayoutForDisplay(home, monitor: mon)
                    if let layoutWS = workspaces.workspaces[home],
                       let assignment = engine.computeFrames(
                           workspace: layoutWS,
                           windows: windowsByID,
                           monitor: mon.layoutFrame,
                           active: true,
                           stackExcluded: stackExcluded,
                           layoutExcluded: layoutExcludedWindowIDs(for: home, monitor: mon)
                       ).first(where: { $0.windowID == id }) {
                        target[id] = assignment.frame
                        if assignment.visible { visibleIDs.insert(id) }
                    } else {
                        needsOrphanRelayout = true
                    }
                } else {
                    // Still not in computeFrames output — reinsert and park until follow-up.
                    // Never assign full usable here (that stacked every orphan on top of each other).
                    needsOrphanRelayout = true
                    if let home {
                        let mon = monitors.monitors.first(where: {
                            workspaces.activeWorkspaceByMonitor[$0.id] == home
                        }) ?? layoutMonitor
                        assignWindow(id, to: home, on: mon)
                    }
                    target[id] = Rect(x: park.x, y: park.y, width: max(win.frame.width, 800), height: max(win.frame.height, 600))
                    visibleIDs.remove(id)
                }
            }
        }
        if needsOrphanRelayout {
            if visibilityOrphanPasses < maxVisibilityOrphanPasses {
                visibilityOrphanPasses += 1
                scheduleVisibilityRefresh(animated: false, delay: 0.12)
            } else {
                visibilityOrphanPasses = 0
            }
        } else {
            visibilityOrphanPasses = 0
        }

        // Floats / scratchpads follow their home workspace (quake handled separately).
        for (id, win) in windowsByID where (win.isFloating || win.isScratchpad) && quake.windowID != id {
            if workspaces.workspaceID(containing: id) != nil { continue }
            let home = authoritativeHome(for: id)
            let onActive = home.map { isHomeActiveOnAnyMonitor($0) } ?? false
            let live = ax.currentFrame(of: id) ?? win.frame
            if onActive, let home {
                let restored = floatFrameForActiveHome(id: id, home: home, live: live, layoutMonitor: layoutMonitor)
                if frameIsOnMonitorShowingHome(home: home, frame: restored) {
                    savedFrames[id] = restored
                }
                target[id] = restored
                visibleIDs.insert(id)
            } else {
                if OffscreenParking.isUsableOnscreenFrame(live, monitors: allMonitorFrames) {
                    savedFrames[id] = live
                } else if let prev = lastFrames[id],
                          OffscreenParking.isUsableOnscreenFrame(prev, monitors: allMonitorFrames) {
                    savedFrames[id] = prev
                }
                var parkFrame = savedFrames[id] ?? live
                parkFrame.x = park.x
                parkFrame.y = park.y
                target[id] = parkFrame
                visibleIDs.remove(id)
            }
        }

        // Per-monitor leak: hide windows whose *target* is on a monitor not showing home.
        // Never use the pre-layout live frame — a new Calendar/3rd tile still has its
        // default size and looks like a leak, then hide+reveal loops forever.
        for id in Array(visibleIDs) {
            if isVisibilityRevealProtected(id) { continue }
            guard let home = authoritativeHome(for: id) else { continue }
            guard let planned = target[id] else { continue }
            if windowsByID[id]?.isTiled == true, isHomeActiveOnAnyMonitor(home) {
                continue
            }
            guard frameLeaksWrongMonitor(home: home, frame: planned) else { continue }
            visibleIDs.remove(id)
            var f = planned
            f.x = park.x
            f.y = park.y
            target[id] = f
        }

        // Quake scratchpad: always docked float on the configured edge (never tiled layout).
        if let qid = quake.windowID {
            let mon = monitors.monitors.first(where: { $0.id == primaryMonitorID }) ?? layoutMonitor
            if quake.isVisible {
                let frame = quake.visibleFrame(settings: configStore.config.settings.quake, monitor: mon)
                target[qid] = frame
                visibleIDs.insert(qid)
            } else {
                let frame = quake.hiddenFrame(settings: configStore.config.settings.quake, monitor: mon)
                target[qid] = frame
                visibleIDs.remove(qid)
            }
        }

        let signature = visibilitySignature(
            activeIDs: activeIDs,
            visibleIDs: visibleIDs,
            target: target
        )
        if signature == lastVisibilitySignature,
           !visibilityForceReveal,
           !needsOrphanRelayout {
            return
        }
        lastVisibilitySignature = signature

        // Never animate hides: interpolating off-screen leaves a clamped strip on the edge.
        let showTarget = Dictionary(uniqueKeysWithValues: target.filter { visibleIDs.contains($0.key) })

        let apply: ([WindowID: Rect]) -> Void = { [weak self] frames in
            guard let self else { return }
            var hideList: [(WindowID, Rect)] = []
            var showList: [(WindowID, Rect)] = []
            self.ax.withMutation {
                for (id, frame) in frames {
                    guard let win = self.windowsByID[id], !win.isIgnored else { continue }
                    // Tiled + floats (incl. quake) all participate in show/hide.
                    if visibleIDs.contains(id) {
                        showList.append((id, frame))
                    } else {
                        hideList.append((id, frame))
                    }
                }

                // 1) Hide same-PID outgoing first (Safari): revealing a sibling activate()s the
                //    process and can yank a merely parked window onto the sibling's display.
                let showPids = Set(showList.map(\.0.pid))
                let hideSharedPid = hideList.filter { showPids.contains($0.0.pid) }
                let hideRest = hideList.filter { !showPids.contains($0.0.pid) }

                for (id, frame) in hideSharedPid {
                    self.hideOutgoingWindow(id, frame: frame, allMonitorFrames: allMonitorFrames)
                }

                // 2) Reveal incoming.
                for (id, frame) in showList {
                    if id == self.quake.windowID {
                        self.ax.setMinimized(false, id: id)
                        self.ax.apply(frame: frame, to: id)
                        self.lastFrames[id] = frame
                        continue
                    }
                    let win = self.windowsByID[id]
                    let target = (win?.isTiled == true && win?.isFloating != true)
                        ? self.clampHorizontalTileFrame(frame, for: id) : frame
                    let electron = win.map { self.needsElectronReflowNudge($0) } ?? false
                    if !self.visibilityForceReveal,
                       !electron,
                       self.ax.isSettled(id: id, frame: target, monitors: allMonitorFrames),
                       !(self.authoritativeHome(for: id).map { self.frameLeaksWrongMonitor(home: $0, frame: self.liveFrameForVisibility(id) ?? target) } ?? false) {
                        self.lastFrames[id] = target
                        continue
                    }
                    // Electron: unminimize before sizing so Chromium lays out against the real tile.
                    if electron, self.ax.isMinimized(id) {
                        self.ax.setMinimized(false, id: id)
                    }
                    self.ax.reveal(frame: target, id: id)
                    if electron {
                        var shrunk = target
                        shrunk.width = max(160, target.width - 24)
                        shrunk.height = max(96, target.height - 24)
                        self.ax.forceFrame(shrunk, id: id)
                        self.ax.forceFrame(target, id: id)
                    }
                    if let live = self.ax.currentFrame(of: id),
                       !OffscreenParking.isUsableOnscreenFrame(live, monitors: allMonitorFrames) {
                        self.ax.reveal(frame: target, id: id)
                    }
                    self.lastFrames[id] = target
                }

                // 3) Hide remaining outgoing (no sibling being revealed this pass).
                for (id, frame) in hideRest {
                    self.hideOutgoingWindow(id, frame: frame, allMonitorFrames: allMonitorFrames)
                }

                // 4) Re-tuck any hide siblings still bleeding onto a display.
                for (id, _) in hideList where id != self.quake.windowID {
                    if self.isVisibilityRevealProtected(id) { continue }
                    if self.isActiveHomeTile(id) { continue }
                    guard let home = self.authoritativeHome(for: id),
                          let live = self.liveFrameForVisibility(id),
                          self.frameLeaksWrongMonitor(home: home, frame: live)
                    else { continue }
                    self.ax.reparkIfLeaking(
                        id: id,
                        monitors: allMonitorFrames,
                        allowMinimize: self.allowMinimizeDespiteSibling(id)
                    )
                    if let still = self.liveFrameForVisibility(id),
                       self.frameLeaksWrongMonitor(home: home, frame: still),
                       self.allowsPerWindowMinimize(id) {
                        self.ax.parkAndHide(frame: still, id: id, monitors: allMonitorFrames)
                    }
                }

                // 5) Sweep: inactive windows still bleeding onto a display (not already parked).
                for (id, win) in self.windowsByID where !visibleIDs.contains(id) && !win.isIgnored {
                    guard id != self.quake.windowID else { continue }
                    if self.isVisibilityRevealProtected(id) { continue }
                    if self.isActiveHomeTile(id) { continue }
                    guard let home = self.authoritativeHome(for: id) else { continue }
                    if let live = self.liveFrameForVisibility(id),
                       self.frameLeaksWrongMonitor(home: home, frame: live) {
                        self.ax.parkOffscreen(frame: live, id: id, monitors: allMonitorFrames)
                        if let still = self.liveFrameForVisibility(id),
                           self.frameLeaksWrongMonitor(home: home, frame: still),
                           self.allowsPerWindowMinimize(id) {
                            self.ax.parkAndHide(frame: live, id: id, monitors: allMonitorFrames)
                        }
                    } else if !self.ax.isMinimized(id),
                              let live = self.liveFrameForVisibility(id),
                              OffscreenParking.isUsableOnscreenFrame(live, monitors: allMonitorFrames) {
                        self.ax.parkOffscreen(
                            frame: self.lastFrames[id] ?? win.frame,
                            id: id,
                            monitors: allMonitorFrames
                        )
                    }
                }

                // 6) Same-PID windows still visible on the wrong monitor after reveal/activate.
                for (id, _) in hideList where id != self.quake.windowID {
                    if self.isVisibilityRevealProtected(id) { continue }
                    if self.isActiveHomeTile(id) { continue }
                    guard self.samePidHasActiveSibling(id),
                          let home = self.authoritativeHome(for: id),
                          let live = self.liveFrameForVisibility(id),
                          self.frameLeaksWrongMonitor(home: home, frame: live)
                    else { continue }
                    self.ax.reparkIfLeaking(
                        id: id,
                        monitors: allMonitorFrames,
                        allowMinimize: self.allowsPerWindowMinimize(id)
                    )
                    if let still = self.liveFrameForVisibility(id),
                       self.frameLeaksWrongMonitor(home: home, frame: still),
                       self.allowsPerWindowMinimize(id) {
                        self.ax.parkAndHide(frame: still, id: id, monitors: allMonitorFrames)
                    }
                }

                self.reparkSamePidEdgeLeaks(on: allMonitorFrames)

                for (id, frame) in hideList {
                    self.lastFrames[id] = frame
                }
            }
            self.ax.suppressNotifications(for: animated ? 0.35 : 0.12)
            self.refreshBorder()

            let leakIDs = hideList.map(\.0).filter { $0 != self.quake.windowID }
            let settledShow = showList.map(\.0)
            if !leakIDs.isEmpty {
                let delays: [Double] = animated ? [0.08, 0.22] : [0.04]
                for delay in delays {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self else { return }
                        guard !self.overlaysCaptureFocus else { return }
                        // A newer visibility/switch pass owns parking now — drop stale sweeps.
                        guard self.visibilityApplyGeneration == applyGeneration else { return }
                        guard !self.isApplyingVisibility else { return }
                        let activeNow = Set(self.workspaces.activeWorkspaceByMonitor.values)
                        self.ax.withMutation {
                            for id in leakIDs {
                                if self.isVisibilityRevealProtected(id) { continue }
                                if self.isActiveHomeTile(id) { continue }
                                if let home = self.authoritativeHome(for: id), activeNow.contains(home),
                                   let live = self.liveFrameForVisibility(id),
                                   !self.frameLeaksWrongMonitor(home: home, frame: live) {
                                    continue
                                }
                                let siblingOnActive = settledShow.contains { other in
                                    other.pid == id.pid && other != id
                                        && (self.authoritativeHome(for: other).map { activeNow.contains($0) } ?? false)
                                }
                                let escalate = !siblingOnActive || self.allowsPerWindowMinimize(id)
                                self.ax.reparkIfLeaking(
                                    id: id,
                                    monitors: allMonitorFrames,
                                    allowMinimize: escalate
                                )
                                if escalate,
                                   let home = self.authoritativeHome(for: id),
                                   let live = self.liveFrameForVisibility(id),
                                   self.frameLeaksWrongMonitor(home: home, frame: live) {
                                    self.ax.parkAndHide(frame: live, id: id, monitors: allMonitorFrames)
                                }
                            }
                            // Only fix show windows that got yanked minimized — don't rewrite settled frames.
                            for id in settledShow {
                                guard let home = self.authoritativeHome(for: id), activeNow.contains(home) else { continue }
                                guard let frame = self.lastFrames[id] else { continue }
                                if self.ax.isMinimized(id)
                                    || !self.ax.isSettled(id: id, frame: frame, monitors: allMonitorFrames) {
                                    self.ax.reveal(frame: frame, id: id)
                                }
                            }
                            self.reparkSamePidEdgeLeaks(on: allMonitorFrames)
                        }
                    }
                }
            }
        }

        if animated, !lastFrames.isEmpty, !showTarget.isEmpty {
            let showFrom = Dictionary(uniqueKeysWithValues: lastFrames.filter { visibleIDs.contains($0.key) })
            animator.onFrame = { frames, _ in apply(frames) }
            animator.onComplete = { frames in
                apply(frames)
                guard !self.overlaysCaptureFocus else { return }
                self.scheduleTileFrameEnforcement()
            }
            ax.suppressNotifications(for: max(0.5, configStore.config.settings.animationDuration + 0.3))
            animator.animate(from: showFrom, to: showTarget)
        } else if !target.isEmpty {
            apply(target)
            if !animated {
                scheduleTileFrameEnforcement()
            }
        }

        if !floatStripped.isEmpty {
            visibilityForceReveal = true
            for wsID in floatStripped where isHomeActiveOnAnyMonitor(wsID) {
                scheduleRebalanceWorkspace(wsID, force: true)
            }
            persistRuntimeState(forceWorkspaceLayouts: floatStripped)
        }
    }

}


// MARK: - AXTrackerDelegate

extension WindowManager {
    public nonisolated func axTrackerDidUpdateWindows(_ windows: [ManagedWindow], axWindows: [WindowID: AXWindow]) {
        Task { @MainActor in
            self.pendingIngestWindows = windows
            self.ingestDebounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, let batch = self.pendingIngestWindows else { return }
                self.pendingIngestWindows = nil
                self.ingest(windows: batch)
            }
            self.ingestDebounceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + self.ingestDebounceInterval, execute: work)
        }
    }

    public nonisolated func axTrackerWindowTitleDidChange(_ id: WindowID, window: ManagedWindow) {
        Task { @MainActor in
            guard var existing = self.windowsByID[id] else { return }
            guard existing.title != window.title else { return }
            existing.title = window.title
            self.windowsByID[id] = existing
            self.refreshStatusItem()
            self.refreshChrome()
        }
    }

    public nonisolated func axTrackerFocusedWindowDidChange(_ id: WindowID?) {
        Task { @MainActor in
            // Quake / notepad own the interaction — ignore AX focus noise from tiles underneath
            // (same idea as plugin panels / menu bar).
            if self.overlaysCaptureFocus {
                if let id, id == self.quake.windowID || self.isQuakeOwned(id) {
                    self.axFocusedWindowID = id
                } else if self.quake.isVisible, let qid = self.quake.windowID {
                    self.axFocusedWindowID = qid
                }
                // Notepad is an ALWM NSPanel (not tracked as ManagedWindow) — never adopt
                // tile focus ids while it is open alone.
                self.refreshChrome()
                return
            }

            self.axFocusedWindowID = id
            guard let id else {
                self.refreshChrome()
                return
            }

            // Settings / plugin panels / menus — relayout and AX noise must not
            // steal keyboard focus from ALWM-owned dialogs.
            if self.chromeBlocksFocusFollowsMouse() {
                self.refreshChrome()
                return
            }

            // AX already focused this window — never call ax.focus again here (raise:true
            // re-enters layout and makes focus bounce between tiled apps).
            // Only suppress bounce from inactive-workspace windows after a switch —
            // clicks on the new workspace must still update column focus / chrome.
            let home = self.windowWorkspace[id]
                ?? self.workspaces.workspaceID(containing: id)
                ?? self.runtimeState.assignment(for: id)
            if Date() < self.suppressWorkspaceFollowUntil {
                let activeIDs = Set(self.workspaces.activeWorkspaceByMonitor.values)
                if let home, !activeIDs.contains(home) {
                    return
                }
            }
            // Tiles sliding under the cursor must not steal AX focus mid-pan.
            if self.isColumnPanActive {
                return
            }

            if let home {
                let activeIDs = Set(self.workspaces.activeWorkspaceByMonitor.values)
                if !activeIDs.contains(home) {
                    // Dock/Cmd-Tab: ingest adopts on-screen sticky windows. Focus noise
                    // from park/restore must not steal or re-raise here.
                    return
                }
            }

            self.focusWindow(id, raise: false)
            self.refreshChrome()
        }
    }

    public nonisolated func axTrackerWindowGeometryChanged(_ id: WindowID) {
        Task { @MainActor in
            self.scheduleGeometryEnforce(for: id)
        }
    }

    public nonisolated func axTrackerWindowDidClose(_ id: WindowID) {
        Task { @MainActor in
            self.handleUserClosedWindow(id)
        }
    }
}
