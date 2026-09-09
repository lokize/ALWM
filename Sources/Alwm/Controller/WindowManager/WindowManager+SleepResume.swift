import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC
import AlwmPluginAPI

// MARK: - System sleep / wake layout recovery

extension WindowManager {
    func scheduleAccessibilityRecoveryScans() {
        runLayoutRecoveryIfNeeded(force: false, delay: 0.8)
        runLayoutRecoveryIfNeeded(force: false, delay: 2.5)
    }

    func savedTiledWindowCount() -> Int {
        runtimeState.snapshot.workspaceLayouts.values.reduce(0) { partial, layout in
            partial + layout.columns.reduce(0) { $0 + $1.windows.count }
        }
    }

    func liveTiledWindowCount() -> Int {
        workspaces.workspaces.values.reduce(0) { partial, ws in
            partial + ws.columns.reduce(0) { $0 + $1.windows.count }
        }
    }

    func needsLayoutRecovery(force: Bool) -> Bool {
        if force { return true }
        if layoutRecoveryAttempts >= maxLayoutRecoveryAttempts { return false }
        if windowsByID.isEmpty, savedTiledWindowCount() > 0 { return true }
        let saved = savedTiledWindowCount()
        let live = liveTiledWindowCount()
        if saved > 0, live < saved { return true }
        for (wsID, snap) in runtimeState.snapshot.workspaceLayouts {
            guard workspaces.workspaces[wsID] != nil else { continue }
            let savedCols = snap.columns.filter { !$0.windows.isEmpty }.count
            let liveCols = workspaces.workspaces[wsID]?.columns.filter { !$0.windows.isEmpty }.count ?? 0
            if savedCols > liveCols { return true }
        }
        return false
    }

    func runLayoutRecoveryIfNeeded(force: Bool, delay: TimeInterval) {
        guard force || layoutRecoveryAttempts < maxLayoutRecoveryAttempts else { return }
        layoutRecoveryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runLayoutRecovery(force: force)
        }
        layoutRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func runLayoutRecovery(force: Bool) {
        guard AXTracker.isTrusted else { return }
        guard needsLayoutRecovery(force: force) || (isResumeRecovering && !framesLookRestoredOnActiveWorkspaces()) else {
            return
        }
        layoutRecoveryAttempts += 1
        isResumeRecovering = true
        suppressIngestReassignUntil = Date().addingTimeInterval(4.0)
        lastVisibilitySignature = nil
        monitors.refresh()
        ax.scanAll()
        isBootstrapping = true
        ingest(windows: ax.currentWindows)
        rematchStickyFromSavedLayouts()
        purgeStaleStickyTokens()
        restoreWorkspaceLayoutsFromDisk()
        _ = ejectWindowsListedOutsideStickyHome()
        retileAccidentalFloats(forceClearOverrides: true)
        reapplyAppRulesToAllWindows()
        enforceQuakeFloat()
        isBootstrapping = false
        postLaunchLayoutGraceUntil = Date().addingTimeInterval(6)
        adoptOrphanWindows(blockingReassign: true)
        prepareAllActiveWorkspaceLayouts()
        visibilityForceReveal = true
        applyActiveWorkspaceTileLayoutsAfterResume()
        applyWorkspaceVisibility(animated: false)
        scheduleTileFrameEnforcement()
        refreshChrome()
        let saved = savedTiledWindowCount()
        let live = liveTiledWindowCount()
        let recovered = layoutLooksRecovered()
            && framesLookRestoredOnActiveWorkspaces()
            && layoutContentMatchesDiskSnapshot()
        if recovered || layoutRecoveryAttempts >= maxLayoutRecoveryAttempts {
            layoutRecoveryAttempts = maxLayoutRecoveryAttempts
            resumeRecoveryEligibleUntil = Date.distantPast
            isResumeRecovering = false
            if recovered {
                // Tokens may have changed — refresh disk only after structure matches.
                persistRuntimeState()
            }
        }
        NSLog(
            "ALWM: layout recovery #%d — windows=%d savedTiles=%d liveTiles=%d recovered=%@",
            layoutRecoveryAttempts,
            windowsByID.count,
            saved,
            live,
            recovered ? "yes" : "no"
        )
    }

    func isInPostLaunchLayoutGrace() -> Bool {
        Date() < postLaunchLayoutGraceUntil
    }

    func setupSystemResumeObservers() {
        for obs in systemObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            NotificationCenter.default.removeObserver(obs)
        }
        systemObservers.removeAll()

        let willSleep = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Must run synchronously — an async Task often never lands before sleep,
            // so wake restores a stale/empty layout.
            MainActor.assumeIsolated {
                self?.prepareForSystemSleep()
            }
        }
        systemObservers.append(willSleep)

        let screensSleep = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.prepareForSystemSleep()
            }
        }
        systemObservers.append(screensSleep)

        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteSystemWakeForResumeRecovery()
                self?.scheduleStaggeredResumeRecovery()
            }
        }
        systemObservers.append(wake)

        let screensWake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.noteSystemWakeForResumeRecovery()
                self?.scheduleStaggeredResumeRecovery()
            }
        }
        systemObservers.append(screensWake)

        let active = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date() < self.resumeRecoveryEligibleUntil else { return }
                self.scheduleSystemResumeRecovery(delay: 1.2)
            }
        }
        systemObservers.append(active)
    }

    func prepareForSystemSleep() {
        isResumeRecovering = false
        // Soft flush only: at willSleep/screensDidSleep AX often already dropped windows.
        // A destructive (force) write would replace the last good disk layout with empties
        // and wake would restore the wrong order/sizes. Shrink guards stay on.
        allowDestructiveLayoutFlush = false
        persistRuntimeState(forceWorkspaceLayouts: Set(workspaces.workspaces.keys))
        preSleepLayoutFingerprint = layoutContentFingerprint()
        NSLog("ALWM: prepared for sleep — fingerprint=%@", preSleepLayoutFingerprint ?? "?")
    }

    func noteSystemWakeForResumeRecovery() {
        // Idle assertions can be dropped across sleep — put them back immediately.
        SleepAssertion.reassertIfNeeded()
        resumeRecoveryEligibleUntil = Date().addingTimeInterval(300)
        layoutRecoveryAttempts = 0
        isResumeRecovering = true
        lastVisibilitySignature = nil
        lastSnapSignature.removeAll()
        forceTileExpandUntil.removeAll()
    }

    func scheduleStaggeredResumeRecovery() {
        for work in resumeRecoveryWorkItems { work.cancel() }
        resumeRecoveryWorkItems.removeAll()
        // Longer tail: Electron/Safari rematerialize window numbers slowly after wake.
        for delay in [0.6, 1.5, 3.0, 6.0, 12.0, 20.0, 32.0, 48.0] {
            let work = DispatchWorkItem { [weak self] in
                self?.recoverAfterSystemResume()
            }
            resumeRecoveryWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    func scheduleSystemResumeRecovery(delay: TimeInterval = 0.6) {
        resumeRecoveryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.recoverAfterSystemResume()
        }
        resumeRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func recoverAfterSystemResume() {
        guard AXTracker.isTrusted else { return }
        isResumeRecovering = true
        suppressIngestReassignUntil = Date().addingTimeInterval(5.0)
        suppressWorkspaceFollowUntil = Date().addingTimeInterval(2.5)
        suppressGeometryEnforce(for: 4.0)
        lastVisibilitySignature = nil

        // Displays can rearrange after lid open / Clamshell — refresh geometry first.
        monitors.refresh()
        syncWorkspacesToMonitors()

        // Prefer disk snapshot over whatever drifted in memory during sleep.
        runtimeState.load()
        loadStickyAssignmentsFromDisk()
        restorePersistedWorkspaces()

        ax.scanAll()
        isBootstrapping = true
        ingest(windows: ax.currentWindows)
        rematchStickyFromSavedLayouts()
        purgeStaleStickyTokens()
        restoreWorkspaceLayoutsFromDisk()
        // Soft heal only — full heal ejects soft-missing AX windows and wrecks restore.
        _ = ejectWindowsListedOutsideStickyHome()
        retileAccidentalFloats(forceClearOverrides: false)
        reapplyAppRulesToAllWindows()
        enforceQuakeFloat()
        isBootstrapping = false
        postLaunchLayoutGraceUntil = Date().addingTimeInterval(6)
        adoptOrphanWindows(blockingReassign: true)
        prepareAllActiveWorkspaceLayouts()

        // Force tile frames on every active workspace (macOS restores pre-park geometry).
        visibilityForceReveal = true
        applyActiveWorkspaceTileLayoutsAfterResume()
        applyWorkspaceVisibility(animated: false)
        scheduleTileFrameEnforcement()
        refreshChrome()

        let recovered = layoutLooksRecovered()
            && framesLookRestoredOnActiveWorkspaces()
            && layoutContentMatchesDiskSnapshot()
        if recovered {
            isResumeRecovering = false
            resumeRecoveryEligibleUntil = Date.distantPast
            // Safe to refresh disk tokens (window numbers may have changed) now that layout matches.
            persistRuntimeState()
            preSleepLayoutFingerprint = nil
        } else {
            // Keep disk snapshot intact until AX catches up — never persist partial columns.
            runLayoutRecoveryIfNeeded(force: true, delay: 2.5)
        }
        NSLog(
            "ALWM: resume recovery — windows=%d savedTiles=%d liveTiles=%d recovered=%@ fpOK=%@",
            windowsByID.count,
            savedTiledWindowCount(),
            liveTiledWindowCount(),
            recovered ? "yes" : "no",
            layoutContentMatchesDiskSnapshot() ? "yes" : "no"
        )
    }

    func applyActiveWorkspaceTileLayoutsAfterResume() {
        for mon in monitors.monitors {
            guard let wsID = workspaces.activeWorkspaceByMonitor[mon.id],
                  let ws = workspaces.workspaces[wsID],
                  !ws.columns.isEmpty
            else { continue }
            markStructuralLayoutChange(wsID)
            applyWorkspaceTileLayout(wsID, on: mon, forceReveal: true, skipHeal: true)
        }
        applyAllActiveStackColumns()
    }

    func purgeStaleStickyTokens() {
        let live = Set(windowsByID.keys)
        let stale = windowWorkspace.keys.filter { !live.contains($0) }
        for id in stale {
            windowWorkspace.removeValue(forKey: id)
        }
        // Keep runtime assignments for live windows only; disk layout refs still restore via rematch.
        runtimeState.pruneWindows(keeping: live)
    }

    /// Token-based fingerprint (debug / legacy). Prefer `layoutContentFingerprint` across sleep —
    /// CGWindow numbers usually change on wake.
    func layoutRecoveryFingerprint() -> String {
        runtimeState.snapshot.workspaceLayouts.keys.sorted().map { wsID in
            guard let snap = runtimeState.snapshot.workspaceLayouts[wsID] else { return "\(wsID):" }
            let cols = snap.columns.map { col in
                col.windows.map { "\($0.bundleID ?? "?"):\($0.token)" }.joined(separator: ",")
                    + "@\(Int(col.width))"
            }.joined(separator: "|")
            return "\(wsID):\(cols)"
        }.joined(separator: ";")
    }

    /// Stable across wake rematch: bundle + normalized title + column width (not CGWindow token).
    func layoutContentFingerprint() -> String {
        workspaces.workspaces.keys.sorted().map { wsID in
            guard let ws = workspaces.workspaces[wsID] else { return "\(wsID):" }
            let cols = ws.columns.map { col in
                col.windows.compactMap { id -> String? in
                    guard let win = windowsByID[id] else { return nil }
                    let bid = win.bundleID ?? "?"
                    let title = Self.normalizedWindowTitle(win.title)
                    return "\(bid):\(title)"
                }.joined(separator: ",")
                    + "@\(Int(col.width.rounded()))"
            }.joined(separator: "|")
            return "\(wsID):\(cols)"
        }.joined(separator: ";")
    }

    /// Live columns match the on-disk snapshot (order + apps + widths), allowing loose title match.
    func layoutContentMatchesDiskSnapshot() -> Bool {
        let diskKeys = Set(runtimeState.snapshot.workspaceLayouts.keys)
        guard !diskKeys.isEmpty else { return true }
        for wsID in diskKeys {
            guard let snap = runtimeState.snapshot.workspaceLayouts[wsID],
                  let ws = workspaces.workspaces[wsID]
            else { return false }
            let snapCols = snap.columns.filter { !$0.windows.isEmpty }
            let liveCols = ws.columns.filter { !$0.windows.isEmpty }
            if snapCols.count != liveCols.count { return false }
            for (snapCol, liveCol) in zip(snapCols, liveCols) {
                if abs(snapCol.width - liveCol.width) > 24 { return false }
                if snapCol.windows.count != liveCol.windows.count { return false }
                for (ref, id) in zip(snapCol.windows, liveCol.windows) {
                    guard let win = windowsByID[id] else { return false }
                    if let bid = ref.bundleID, !bid.isEmpty, win.bundleID != bid { return false }
                    let rt = Self.normalizedWindowTitle(ref.title)
                    let wt = Self.normalizedWindowTitle(win.title)
                    if !rt.isEmpty, !wt.isEmpty,
                       rt != wt, !Self.titlesLooselyMatch(rt, wt) {
                        return false
                    }
                }
            }
        }
        return true
    }

    func framesLookRestoredOnActiveWorkspaces() -> Bool {
        let monitorFrames = monitors.monitors.map(\.frame)
        for mon in monitors.monitors {
            guard let wsID = workspaces.activeWorkspaceByMonitor[mon.id],
                  let ws = workspaces.workspaces[wsID]
            else { continue }
            let usable = engine.usableArea(monitor: mon.layoutFrame)
            for col in ws.columns {
                for id in col.windows {
                    guard windowsByID[id]?.isTiled == true else { continue }
                    let frame = ax.currentFrame(of: id) ?? lastFrames[id]
                    guard let frame else { return false }
                    guard OffscreenParking.isUsableOnscreenFrame(frame, monitors: monitorFrames) else {
                        return false
                    }
                    // Midpoint must land on the home monitor (not the display below).
                    if let host = monitors.monitorContaining(pointX: frame.midX, pointY: frame.midY),
                       host.id != mon.id {
                        return false
                    }
                    // Rough size sanity — tiny/collapsed frames mean AX hasn't accepted layout yet.
                    if frame.width < usable.width * 0.12, ws.columns.count <= 3 {
                        return false
                    }
                }
            }
        }
        return true
    }

    func layoutLooksRecovered() -> Bool {
        let saved = savedTiledWindowCount()
        let live = liveTiledWindowCount()
        if saved == 0 { return true }
        if live < saved { return false }
        for (wsID, snap) in runtimeState.snapshot.workspaceLayouts {
            guard workspaces.workspaces[wsID] != nil else { continue }
            let savedCols = snap.columns.filter { !$0.windows.isEmpty }.count
            let liveCols = workspaces.workspaces[wsID]?.columns.filter { !$0.windows.isEmpty }.count ?? 0
            if savedCols > liveCols { return false }
            let savedTiles = snap.columns.reduce(0) { $0 + $1.windows.count }
            let liveTiles = workspaces.workspaces[wsID]?.columns.reduce(0) { $0 + $1.windows.count } ?? 0
            if savedTiles > liveTiles { return false }
        }
        return true
    }

}
