import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC
import AlwmPluginAPI

enum ResumeWorkspaceSelection {
    static func matches(
        active: [CGDirectDisplayID: String],
        expected: [CGDirectDisplayID: String]
    ) -> Bool {
        expected.allSatisfy { active[$0.key] == $0.value }
    }

    static func expectedWorkspace(
        allowed: [String],
        savedForMonitor: String?,
        savedGlobally: String?,
        existing: Set<String>
    ) -> String? {
        if let savedForMonitor, allowed.contains(savedForMonitor), existing.contains(savedForMonitor) {
            return savedForMonitor
        }
        if let savedGlobally, allowed.contains(savedGlobally), existing.contains(savedGlobally) {
            return savedGlobally
        }
        return allowed.first(where: existing.contains)
    }
}

enum WorkspaceWindowRecoveryPolicy {
    static func bundleIDs(workspaceID: String, snapshot: RuntimeStateStore.Snapshot) -> Set<String> {
        var result = Set(snapshot.bundleWorkspace.compactMap { bundleID, savedWorkspace in
            savedWorkspace == workspaceID ? bundleID : nil
        })
        guard let layout = snapshot.workspaceLayouts[workspaceID] else { return result }
        for ref in layout.columns.flatMap(\.windows) + layout.floating {
            if let bundleID = ref.bundleID {
                result.insert(bundleID)
            }
        }
        return result
    }

    static func shouldRescan(
        workspaceID: String,
        snapshot: RuntimeStateStore.Snapshot,
        liveWindows: [ManagedWindow]
    ) -> Bool {
        let liveTokens = Set(liveWindows.map { $0.id.token })
        if let layout = snapshot.workspaceLayouts[workspaceID] {
            let refs = layout.columns.flatMap(\.windows) + layout.floating
            if refs.contains(where: { !liveTokens.contains($0.token) }) {
                return true
            }
        }
        let liveBundles = Set(liveWindows.compactMap(\.bundleID))
        return snapshot.bundleWorkspace.contains { bundleID, savedWorkspace in
            savedWorkspace == workspaceID && !liveBundles.contains(bundleID)
        }
    }

}

enum ResumeFrameSelection {
    static func matches(
        actual: Rect,
        expected: Rect,
        usable: Rect,
        monitorFrames: [Rect],
        minSize: Size,
        isMinimized: Bool = false
    ) -> Bool {
        guard !isMinimized else { return false }
        // Scrolled columns and maximized siblings are intentionally parked. Their
        // exact off-screen origin can change when displays reconnect after sleep.
        if !OffscreenParking.intersectsAnyMonitor(expected, monitors: monitorFrames) {
            return !OffscreenParking.intersectsAnyMonitor(actual, monitors: monitorFrames)
        }
        // A horizontally scrolled column can be partly visible with its midpoint
        // outside the monitor. Compare its geometry instead of calling it parked.
        guard OffscreenParking.intersectsAnyMonitor(actual, monitors: monitorFrames) else {
            return false
        }
        if OffscreenParking.isUsableOnscreenFrame(expected, monitors: monitorFrames),
           !OffscreenParking.isUsableOnscreenFrame(actual, monitors: monitorFrames) {
            return false
        }
        let targetWidth = max(expected.width, minSize.width)
        let targetHeight = max(expected.height, minSize.height)
        let xTolerance = max(12, expected.width * 0.025)
        let yTolerance = max(20, expected.height * 0.04)
        let widthTolerance = max(20, targetWidth * 0.05)
        let heightTolerance = max(24, targetHeight * 0.08)
        return abs(actual.x - expected.x) <= xTolerance
            && abs(actual.y - expected.y) <= yTolerance
            && abs(actual.width - targetWidth) <= widthTolerance
            && abs(actual.height - targetHeight) <= heightTolerance
            && actual.width >= usable.width * 0.12
    }
}

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
        if !persistedWorkspaceSelectionMatchesCurrent() { return true }
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
        guard needsLayoutRecovery(force: force)
                || (isResumeRecovering
                    && (!persistedWorkspaceSelectionMatchesCurrent() || !framesLookRestoredOnActiveWorkspaces())) else {
            return
        }
        layoutRecoveryAttempts += 1
        isResumeRecovering = true
        suppressIngestReassignUntil = Date().addingTimeInterval(4.0)
        lastVisibilitySignature = nil
        monitors.refresh()
        syncWorkspacesToMonitors()
        runtimeState.load()
        restorePersistedWorkspaces()
        ax.scanAll()
        isBootstrapping = true
        ingest(windows: ax.currentWindows)
        rematchStickyFromSavedLayouts()
        purgeStaleStickyTokens()
        restoreWorkspaceLayoutsFromDisk()
        _ = ejectWindowsListedOutsideStickyHome()
        retileAccidentalFloats(forceClearOverrides: true)
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
            && persistedWorkspaceSelectionMatchesCurrent()
            && framesLookRestoredOnActiveWorkspaces()
            && layoutContentMatchesDiskSnapshot()
        if recovered {
            finishResumeRecoverySuccessfully()
        } else if layoutRecoveryAttempts >= maxLayoutRecoveryAttempts {
            // Stop hammering AX, but keep disk freeze briefly so a partial layout isn't saved.
            cancelPendingResumeRecovery()
            layoutRecoveryAttempts = maxLayoutRecoveryAttempts
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.isResumeRecovering else { return }
                self.isResumeRecovering = false
                self.resumeRecoveryEligibleUntil = Date.distantPast
                self.softPersistProtectMissingTokens = false
                self.layoutMutationFrozenUntil = Date.distantPast
                NSLog("ALWM: layout recovery gave up — disk snapshot preserved")
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
        cancelPendingResumeRecovery()
        cancelPendingRebalances()
        isResumeRecovering = false
        // Soft flush only: at willSleep/screensDidSleep AX often already dropped windows.
        // Keep protect flags until wake recovery — a defer here used to clear them before
        // AX finished dropping windows, so rebalance persisted 1-column layouts to disk.
        allowDestructiveLayoutFlush = false
        softPersistProtectMissingTokens = true
        // Must keep eligibility in the future — otherwise clearStaleLayoutMutationFreezeIfNeeded
        // wipes softPersist on the next isLayoutMutationFrozen check (eligible was distantPast),
        // ingest treats the AX mass-drop as red-X closes, and quit-last-window kills Discord /
        // WhatsApp / Safari (move.log 2026-09-18T15:53:33Z).
        resumeRecoveryEligibleUntil = Date().addingTimeInterval(24 * 60 * 60)
        layoutMutationFrozenUntil = Date().addingTimeInterval(24 * 60 * 60)
        // Capture fingerprint while memory still looks good (before any soft write).
        if liveTiledWindowCount() > 0 {
            preSleepLayoutFingerprint = layoutContentFingerprint()
        }
        // Do not force every workspace — when live < disk, persist skips shrinking layouts.
        persistRuntimeState()
        NSLog("ALWM: prepared for sleep — fingerprint=%@", preSleepLayoutFingerprint ?? "?")
    }

    func noteSystemWakeForResumeRecovery() {
        // Idle assertions can be dropped across sleep — put them back immediately.
        SleepAssertion.reassertIfNeeded()
        cancelPendingRebalances()
        resumeRecoveryEligibleUntil = Date().addingTimeInterval(300)
        layoutRecoveryAttempts = 0
        isResumeRecovering = true
        // Keep softPersistProtectMissingTokens until finishResumeRecoverySuccessfully.
        softPersistProtectMissingTokens = true
        layoutMutationFrozenUntil = Date().addingTimeInterval(300)
        lastVisibilitySignature = nil
        lastSnapSignature.removeAll()
        forceTileExpandUntil.removeAll()
    }

    /// Accessibility can drop several windows without delivering a macOS wake event.
    /// A previous successful recovery sets attempts to the maximum, so that event
    /// otherwise leaves the stripped in-memory columns unrecoverable until relaunch.
    func noteAXMassDropForRecovery() {
        guard !isBootstrapping, !isResumeRecovering else { return }
        noteSystemWakeForResumeRecovery()
        scheduleStaggeredResumeRecovery()
        logMove("resume recovery armed after AX mass-drop")
    }

    func cancelPendingResumeRecovery() {
        resumeRecoveryWorkItem?.cancel()
        resumeRecoveryWorkItem = nil
        for work in resumeRecoveryWorkItems { work.cancel() }
        resumeRecoveryWorkItems.removeAll()
        layoutRecoveryWorkItem?.cancel()
        layoutRecoveryWorkItem = nil
    }

    func cancelPendingRebalances() {
        for (_, work) in rebalanceWorkItems { work.cancel() }
        rebalanceWorkItems.removeAll()
    }

    var isLayoutMutationFrozen: Bool {
        // Stuck freeze after incomplete wake used to block tiling forever (Finder etc.).
        clearStaleLayoutMutationFreezeIfNeeded()
        return softPersistProtectMissingTokens
            || isResumeRecovering
            || Date() < layoutMutationFrozenUntil
    }

    /// Drop sleep/wake freeze once recovery eligibility ended and we are not mid-recover.
    func clearStaleLayoutMutationFreezeIfNeeded() {
        // Stuck isResumeRecovering after incomplete wake blocked move persist for hours
        // (Safari/Cursor snapped back to disk WS on mass-restore — move.log).
        if isResumeRecovering, Date() >= resumeRecoveryEligibleUntil {
            isResumeRecovering = false
            softPersistProtectMissingTokens = false
            layoutMutationFrozenUntil = Date.distantPast
            NSLog("ALWM: cleared stuck resume recovery freeze")
            return
        }
        guard softPersistProtectMissingTokens || Date() < layoutMutationFrozenUntil else { return }
        guard !isResumeRecovering else { return }
        // Still inside the wake eligibility window — keep protecting disk.
        if Date() < resumeRecoveryEligibleUntil { return }
        softPersistProtectMissingTokens = false
        layoutMutationFrozenUntil = Date.distantPast
        NSLog("ALWM: cleared stale layout mutation freeze")
    }

    func finishResumeRecoverySuccessfully() {
        cancelPendingResumeRecovery()
        layoutRecoveryAttempts = maxLayoutRecoveryAttempts
        isResumeRecovering = false
        resumeRecoveryEligibleUntil = Date.distantPast
        softPersistProtectMissingTokens = false
        layoutMutationFrozenUntil = Date.distantPast
        // Safe to refresh disk tokens (window numbers may have changed) now that layout matches.
        persistRuntimeState()
        preSleepLayoutFingerprint = nil
    }

    func scheduleStaggeredResumeRecovery() {
        cancelPendingResumeRecovery()
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
        // Staggered retries must not re-enter after a successful pass this wake.
        guard isResumeRecovering || Date() < resumeRecoveryEligibleUntil else { return }
        // If live already matches disk, finish instead of rematching again (spam wrecked widths).
        let workspaceSelectionMatches = persistedWorkspaceSelectionMatchesCurrent()
        if workspaceSelectionMatches,
           layoutLooksRecovered(),
           framesLookRestoredOnActiveWorkspaces(),
           layoutContentMatchesDiskSnapshot() {
            finishResumeRecoverySuccessfully()
            NSLog("ALWM: resume recovery — already matched, skipping rematch")
            return
        }
        if !workspaceSelectionMatches {
            logMove("resume recovery fast-path skipped — active workspace differs from saved selection")
        }
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
            && persistedWorkspaceSelectionMatchesCurrent()
            && framesLookRestoredOnActiveWorkspaces()
            && layoutContentMatchesDiskSnapshot()
        if recovered {
            finishResumeRecoverySuccessfully()
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

    func persistedWorkspaceSelectionMatchesCurrent() -> Bool {
        let existing = Set(workspaces.workspaces.keys)
        var expected: [CGDirectDisplayID: String] = [:]
        for (index, monitor) in monitors.monitors.enumerated() {
            let allowed = workspaces.definitionsVisible(onMonitorIndex: index).map(\.id)
            let savedForMonitor = runtimeState.snapshot.lastWorkspaceByMonitor[String(monitor.id)]
            if let workspaceID = ResumeWorkspaceSelection.expectedWorkspace(
                allowed: allowed,
                savedForMonitor: savedForMonitor,
                savedGlobally: runtimeState.snapshot.lastWorkspace,
                existing: existing
            ) {
                expected[monitor.id] = workspaceID
            }
        }
        return ResumeWorkspaceSelection.matches(
            active: workspaces.activeWorkspaceByMonitor,
            expected: expected
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
    /// Widths are compared by ratio when absolute px diverge (resume may renormalize overflow layouts).
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
            let snapSum = snapCols.reduce(0.0) { $0 + max(1, $1.width) }
            let liveSum = liveCols.reduce(0.0) { $0 + max(1, $1.width) }
            for (snapCol, liveCol) in zip(snapCols, liveCols) {
                if snapCol.windows.count != liveCol.windows.count { return false }
                let absOK = abs(snapCol.width - liveCol.width) <= 24
                let snapR = max(1, snapCol.width) / snapSum
                let liveR = max(1, liveCol.width) / liveSum
                let ratioOK = abs(snapR - liveR) <= 0.08
                if !absOK && !ratioOK { return false }
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
            let assignments = engine.computeFrames(
                workspace: ws,
                windows: windowsByID,
                monitor: mon.layoutFrame,
                active: true,
                stackExcluded: stackExcludedFromLayout(),
                layoutExcluded: layoutExcludedWindowIDs(for: wsID)
            )
            let expectedByID = Dictionary(
                assignments.map { ($0.windowID, $0.frame) },
                uniquingKeysWith: { _, last in last }
            )
            for col in ws.columns {
                for id in col.windows {
                    guard let win = windowsByID[id], win.isTiled else { continue }
                    guard let expected = expectedByID[id],
                          let actual = ax.currentFrame(of: id),
                          ResumeFrameSelection.matches(
                            actual: actual,
                            expected: expected,
                            usable: usable,
                            monitorFrames: monitorFrames,
                            minSize: win.minSize,
                            isMinimized: ax.isMinimized(id)
                          ) else {
                        return false
                    }
                    // Midpoint must land on the home monitor for visible tiles.
                    if OffscreenParking.isUsableOnscreenFrame(expected, monitors: monitorFrames),
                       let host = monitors.monitorContaining(pointX: actual.midX, pointY: actual.midY),
                       host.id != mon.id {
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
