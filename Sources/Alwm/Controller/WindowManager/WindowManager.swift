import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC
import AlwmPluginAPI

// MARK: - WindowManager core — state, start/stop, applyConfig

@MainActor
public final class WindowManager: NSObject, AXTrackerDelegate {
    public let configStore = ConfigStore()

    public let monitors = MonitorStore()

    public let workspaces = WorkspaceStore()

    public let ax = AXTracker()

    public let hotkeys = HotkeyManager()

    public let border = FocusBorderOverlay()

    public let bar = WorkspaceBarController()

    public let overview = OverviewController()

    public let animator = LayoutAnimator()

    public let ipc = IPCServer()

    public let quake = QuakeTerminalController()

    public let notepad = NotepadController()

    public let palette = CommandPaletteController()

    public let settingsUI = SettingsWindowController()

    public let gestures = GestureScrollMonitor()

    public let statusPopover = StatusPopoverController()

    let capture = CaptureController()

    let colorPalette = ColorPaletteController()

    var engine = LayoutEngineRouter()

    var windowsByID: [WindowID: ManagedWindow] = [:]

    var lastFrames: [WindowID: Rect] = [:]

    var primaryMonitorID: CGDirectDisplayID = 0

    var mouseMonitor: Any?

    var mouseMoveEventBridge: AppKitEventMonitorBridge?

    var ffmWorkItem: DispatchWorkItem?

    var ffmLastRun = Date.distantPast

    var appPopupOpenCache: (at: Date, value: Bool)?

    var quakeClickMonitor: Any?

    var quakeClickLocalMonitor: Any?

    var quakeClickEventBridge: AppKitEventMonitorBridge?

    var suppressQuakeDismissUntil = Date.distantPast

    var quakeCloseConfirmWorkItem: DispatchWorkItem?
    var suppressNotepadDismissUntil = Date.distantPast
    enum OverlayFocusTarget { case quake, notepad }

    var preferredOverlayFocus: OverlayFocusTarget?

    var overlaysCaptureFocus: Bool {
        quake.isVisible || notepad.isVisible
    }

    var statusItem: NSStatusItem?

    var statusItemClickBridge: StatusItemClickBridge?

    var statusMarquee = StatusMarqueeController()

    var focusSourceIsMouse = false

    var floatingOverrides: Set<WindowID> = []

    var axFocusedWindowID: WindowID?

    var windowWorkspace: [WindowID: String] = [:]

    var missingScanCounts: [WindowID: Int] = [:]

    var windowFirstTrackedAt: [WindowID: Date] = [:]

    let newWindowColumnGrace: TimeInterval = 2.0

    let floatRevealGrace: TimeInterval = 3.0

    var forcedFloatVisibleUntil: [WindowID: Date] = [:]

    var forceTileExpandUntil: [String: Date] = [:]

    let structuralTileExpandDuration: TimeInterval = 2.5

    var suppressIngestReassignUntil = Date.distantPast

    var forcedTiledUntil: [WindowID: Date] = [:]

    var lastMoveDedupe: (WindowID, String, Date)?

    var lastTileMoveDedupe: (String, String, Date)?

    var savedFrames: [WindowID: Rect] = [:]

    var ingestRelayoutWorkItem: DispatchWorkItem?

    var ingestDebounceWorkItem: DispatchWorkItem?

    var pendingIngestWindows: [ManagedWindow]?

    let ingestDebounceInterval: TimeInterval = 0.065

    var rebalanceWorkItems: [String: DispatchWorkItem] = [:]

    var tokenByWindowToken: [String: WindowID] = [:]

    var lastVisibilitySignature: String?

    var structuralHealDoneThisPass = false

    var geometryEnforceWorkItem: DispatchWorkItem?

    var geometryEnforcePending: Set<WindowID> = []

    var suppressGeometryEnforceUntil = Date.distantPast

    var isApplyingVisibility = false

    var pendingVisibilityAnimated: Bool?

    let runtimeState = RuntimeStateStore()

    var isBootstrapping = true

    var layoutRecoveryWorkItem: DispatchWorkItem?

    var layoutRecoveryAttempts = 0

    let maxLayoutRecoveryAttempts = 8

    var suppressWorkspaceFollowUntil = Date.distantPast

    var workspaceSwitchGeneration: UInt64 = 0

    var visibilityApplyGeneration: UInt64 = 0

    var systemObservers: [NSObjectProtocol] = []

    var resumeRecoveryWorkItem: DispatchWorkItem?

    var resumeRecoveryWorkItems: [DispatchWorkItem] = []

    var resumeRecoveryEligibleUntil = Date.distantPast

    var isResumeRecovering = false

    /// When true, `persistRuntimeState(forceWorkspaceLayouts:)` may shrink/overwrite richer disk snapshots.
    /// Keep false for sleep/wake — AX often blips windows right as the Mac sleeps.
    var allowDestructiveLayoutFlush = false

    var skipRestoreOnStopForUpdate = false

    var postLaunchLayoutGraceUntil = Date.distantPast

    var preSleepLayoutFingerprint: String?

    var layoutExcludedCache: [String: Set<WindowID>] = [:]

    var minimizedCache: [WindowID: Bool] = [:]

    var visibilityOrphanPasses = 0

    let maxVisibilityOrphanPasses = 1

    var visibilityForceReveal = false

    var visibilityDeferredWhileOverlay = false

    var gesturesPausedForOverlay = false

    var appRuleFramesApplied: Set<WindowID> = []

    var forceAppRuleFrameApply = false

    var appRulesSignature = ""

    public override init() {
        super.init()
    }

    public func start() throws {
        // Required permissions are gated in AppDelegate. Soft-request only if somehow missing.
        if !Permissions.accessibilityGranted() {
            Permissions.requestAccessibility()
        }
        if !Permissions.inputMonitoringGranted() {
            Permissions.requestInputMonitoring()
        }
        // Optional: enables Overview thumbnails (CGWindowListCreateImage).
        if !Permissions.screenRecordingGranted() {
            // Do not prompt here — user can grant from Settings / Permissions gate.
        }

        try configStore.load()
        applyConfig(configStore.config)
        AppUpdateService.shared.checkForUpdates()
        configStore.onChange = { [weak self] config in
            Task { @MainActor in
                self?.applyConfig(config)
            }
        }
        configStore.startWatching()

        monitors.startObserving()
        monitors.onChange = { [weak self] in
            Task { @MainActor in
                self?.syncWorkspacesToMonitors()
                self?.relayout(animated: false)
                self?.refreshChrome()
            }
        }
        syncWorkspacesToMonitors()
        restorePersistedWorkspaces()
        loadStickyAssignmentsFromDisk()

        ax.delegate = self
        ax.scanAll()
        // Do not restoreAllOnscreen here — that fights workspace parking.
        // Bootstrap ingest must NOT persist — that used to wipe workspaceLayouts on disk
        // before restoreWorkspaceLayoutsFromDisk could read them.
        ingest(windows: ax.currentWindows)
        rematchStickyFromSavedLayouts()
        restoreWorkspaceLayoutsFromDisk()
        healStaleColumnEntries()
        retileAccidentalFloats(forceClearOverrides: true)
        enforceAppRuleFloats()
        enforceQuakeFloat()
        adoptOrphanWindows(blockingReassign: false)
        isBootstrapping = false
        // AX + token rematch lag after relaunch/update — don't dump orphans onto active WS yet.
        postLaunchLayoutGraceUntil = Date().addingTimeInterval(6)
        layoutRecoveryAttempts = 0
        prepareAllActiveWorkspaceLayouts()
        persistRuntimeState()
        applyWorkspaceVisibility(animated: false)
        ax.start()
        setupSystemResumeObservers()
        // Accessibility can lag behind the TCC toggle — keep trying briefly after launch.
        scheduleAccessibilityRecoveryScans()
        scheduleSystemResumeRecovery(delay: 1.0)

        hotkeys.onAction = { [weak self] action in
            Task { @MainActor in
                self?.focusSourceIsMouse = false
                self?.handleAction(action)
            }
        }
        hotkeys.shouldDeferHotkeys = { [weak self] in
            guard let self else { return false }
            return self.notepad.isVisible || self.quake.isVisible
        }
        updateOverlayInputMode()
        // Register after onAction is wired (applyConfig may have registered too early).
        hotkeys.register(bindings: configStore.config.hotkeys)
        updateOverlayInputMode()

        PluginManager.shared.onBarRefreshNeeded = { [weak self] in
            self?.refreshChrome()
        }
        PluginManager.shared.onPluginAutoDisabled = { [weak self] id in
            self?.notifyPluginAutoDisabled(id)
        }
        // Defer so the first chrome paint isn't blocked by plugin dlopen/SMC/HID.
        DispatchQueue.main.async {
            PluginInstallService.shared.ensureUserPlugInsDir()
            PluginInstallService.shared.restoreInstalledIfNeeded()
        }

        AppUpdateService.shared.onPrepareQuitForUpdate = { [weak self] in
            self?.persistRuntimeStateBeforeUpdate()
        }

        bar.onSelectWorkspace = { [weak self] monitorID, workspaceID in
            Task { @MainActor in
                self?.switchWorkspace(id: workspaceID, on: monitorID)
            }
        }
        bar.onFocusWorkspaceWindow = { [weak self] monitorID, workspaceID, windowID in
            Task { @MainActor in
                self?.focusWorkspaceWindow(windowID, workspaceID: workspaceID, on: monitorID)
            }
        }
        bar.onMoveFocusedToWorkspace = { [weak self] workspaceID, follow in
            Task { @MainActor in
                self?.moveFocusedToWorkspace(workspaceID, follow: follow)
            }
        }
        bar.onMoveWindowToWorkspace = { [weak self] windowID, workspaceID, follow in
            Task { @MainActor in
                self?.moveWindow(requestedID: windowID, to: workspaceID, follow: follow)
            }
        }
        bar.onCloseWindow = { [weak self] windowID in
            Task { @MainActor in
                self?.closeWindow(windowID)
            }
        }
        bar.onQuitApp = { [weak self] pid in
            Task { @MainActor in
                self?.quitApp(pid: pid)
            }
        }
        bar.onToggleFloatWindow = { [weak self] windowID in
            Task { @MainActor in
                self?.toggleFloat(windowID)
            }
        }
        bar.onFocusFloatingOnMonitor = { [weak self] monitorID in
            Task { @MainActor in
                self?.focusFloatingWindow(on: monitorID)
            }
        }
        bar.onFocusedStatusClicked = { [weak self] anchor in
            Task { @MainActor in
                guard let self else { return }
                let s = self.configStore.config.settings
                self.statusPopover.update(
                    focusFollowsMouse: s.focusFollowsMouse,
                    borders: s.borders.enabled,
                    workspaceBar: s.workspaceBar.enabled,
                    preventSleep: s.preventDisplaySleep,
                    developerMode: s.developerMode,
                    version: AlwmVersion.installed,
                    isRecording: self.capture.isRecording,
                    recentNotes: self.notepad.store.recentPreviews()
                )
                self.statusPopover.toggle(relativeTo: anchor)
            }
        }
        // Live window list for multi-window picker — all open windows of the app,
        // across every workspace/monitor (user picks one → we focus/switch to it).
        bar.onWindowsForApp = { [weak self] bundleID, appName, workspaceID -> [ManagedWindow] in
            guard let self else { return [] }

            func matchesApp(_ win: ManagedWindow) -> Bool {
                guard !win.isIgnored, !win.isScratchpad else { return false }
                if let bid = bundleID, !bid.isEmpty { return win.bundleID == bid }
                return win.appName == appName
            }

            let liveAX = Set(self.ax.currentWindows.map(\.id))
            var seen = Set<WindowID>()
            var result: [ManagedWindow] = []
            for (id, win) in self.windowsByID {
                guard matchesApp(win), seen.insert(id).inserted else { continue }
                // Prefer windows still present in AX; keep briefly soft-missing if sticky.
                if liveAX.contains(id) || self.windowWorkspace[id] != nil {
                    result.append(win)
                }
            }

            self.logMove(
                "bar-pick app=\(bundleID ?? appName) chipWS=\(workspaceID) candidates=\(result.count) tokens=\(result.map(\.id.token).joined(separator: ","))"
            )
            return result
        }
        overview.onSelectWorkspace = { [weak self] workspaceID in
            Task { @MainActor in
                guard let self else { return }
                self.switchWorkspace(id: workspaceID, on: self.primaryMonitorID)
            }
        }
        quake.onNeedRescan = { [weak self] in
            self?.ax.scanAll()
        }
        quake.onAdopted = { [weak self] id in
            guard let self else { return }
            self.workspaces.removeWindowEverywhere(id)
            self.floatingOverrides.insert(id)
            self.windowWorkspace.removeValue(forKey: id)
            self.runtimeState.setAssignment(nil, for: id)
            self.runtimeState.setQuakeWindowToken(id.token)
            if var win = self.windowsByID[id] {
                win.isFloating = true
                win.isScratchpad = true
                self.windowsByID[id] = win
            }
            self.quake.markScratchpad(in: &self.windowsByID)
            // Fresh adopt — don't let AX focus bounce dismiss the new panel.
            self.suppressQuakeDismissUntil = Date().addingTimeInterval(1.0)
            self.persistRuntimeState()
            // Quake may have been briefly tiled before adopt — restore full tile frames
            // sync (no animation) so a half-lerp never sticks until the next column move.
            self.relayout(animated: false)
            self.refreshChrome()
            NSLog("ALWM Quake: adopted %@ as floating scratchpad", id.token)
        }
        palette.onRun = { [weak self] action in
            self?.focusSourceIsMouse = false
            self?.handleAction(action)
        }
        settingsUI.onSave = { [weak self] config in
            guard let self else { return }
            var synced = config
            synced.hotkeys = ConfigStore.syncWorkspaceHotkeys(
                workspaces: synced.workspaces,
                hotkeys: synced.hotkeys
            )
            self.configStore.replaceConfig(synced)
            self.applyConfig(synced)
            self.relayout(animated: true)
            self.refreshChrome()
            self.refreshStatusItem()
        }
        settingsUI.onDump = { [weak self] in
            self?.dumpRuntimeState()
        }
        settingsUI.onRevealConfig = {
            NSWorkspace.shared.open(ConfigPaths.root)
        }
        settingsUI.onResetRuntime = { [weak self] in
            self?.resetRuntimeState()
        }
        settingsUI.onRerunOnboarding = { [weak self] in
            self?.showPermissionsHelp()
        }
        settingsUI.monitorsProvider = { [weak self] in
            self?.monitors.monitors ?? []
        }
        settingsUI.runningAppsProvider = { [weak self] in
            self?.runningAppsForRules() ?? []
        }
        settingsUI.onCaptureAppRuleFrame = { [weak self] bundleID in
            self?.captureAppRuleGeometry(bundleID: bundleID)
        }
        settingsUI.onApplyRulesNow = { [weak self] in
            self?.applyAppRulesNow()
        }
        settingsUI.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            // Same pause as palette / plugin panels / quake: no FFM chase, no focus ring.
            if visible {
                self.border.hide()
            } else {
                self.refreshBorder()
            }
        }

        setupStatusItem()
        notepad.store.onIndexChanged = { [weak self] in
            self?.refreshStatusItem()
        }
        notepad.onClose = { [weak self] in
            guard let self, let mon = self.monitorForAction() ?? self.primaryMonitor() else { return }
            self.dismissNotepad(on: mon)
        }
        notepad.onVisibilityChanged = { [weak self] _ in
            self?.updateOverlayInputMode()
        }
        quake.onVisibilityChanged = { [weak self] _ in
            self?.updateOverlayInputMode()
        }
        setupFocusFollowsMouse()
        setupOverlayClickOutside()
        setupGestures()
        try startIPC()

        applyConfig(configStore.config)
        relayout(animated: false)
        refreshChrome()
        refreshStatusItem()

        if !configStore.config.settings.onboardingCompleted {
            if Permissions.snapshot().requiredGranted {
                mutateSettings { $0.onboardingCompleted = true }
            } else {
                showPermissionsHelp()
            }
        }

        NSApplication.shared.setActivationPolicy(.accessory)
    }

    public func stop() {
        persistRuntimeState()
        for obs in systemObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            NotificationCenter.default.removeObserver(obs)
        }
        systemObservers.removeAll()
        resumeRecoveryWorkItem?.cancel()
        resumeRecoveryWorkItem = nil
        for work in resumeRecoveryWorkItems { work.cancel() }
        resumeRecoveryWorkItems.removeAll()
        quake.hideBlur()
        SleepAssertion.setPreventDisplaySleep(false)
        // Update quit already persisted layouts — don't yank every window onscreen
        // (that raced the replace helper and scrambled the next restore).
        if !skipRestoreOnStopForUpdate {
            let frames = monitors.monitors.map(\.frame)
            ax.restoreAllOnscreen(monitors: frames)
        }
        skipRestoreOnStopForUpdate = false
        ax.stop()
        hotkeys.unregisterAll()
        ipc.stop()
        border.hide()
        bar.hideAll()
        overview.hide()
        palette.hide()
        gestures.stop()
        gestureInertiaWorkItem?.cancel()
        gestureScrollIdleWorkItem?.cancel()
        gestureDidContinuousScroll = false
        isGestureScrolling = false
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        mouseMoveEventBridge = nil
        if let quakeClickMonitor {
            NSEvent.removeMonitor(quakeClickMonitor)
            self.quakeClickMonitor = nil
        }
        if let quakeClickLocalMonitor {
            NSEvent.removeMonitor(quakeClickLocalMonitor)
            self.quakeClickLocalMonitor = nil
        }
        quakeClickEventBridge = nil
        animator.stop()
    }

    func applyConfig(_ config: AlwmConfig) {
        engine.applySettings(config.settings)
        animator.duration = config.settings.animationDuration
        if config.settings.borders.enabled {
            border.updateStyle(
                width: config.settings.borders.width,
                hex: config.settings.borders.colorHex
            )
        } else {
            border.hide()
        }
        hotkeys.register(bindings: config.hotkeys)
        updateOverlayInputMode()
        syncWorkspacesToMonitors()
        setupFocusFollowsMouse()
        setupOverlayClickOutside()
        setupGestures()
        applyAppearanceTheme(config.settings.theme)
        LocalizationController.shared.apply(config.settings.language)
        SleepAssertion.setPreventDisplaySleep(config.settings.preventDisplaySleep)
        LaunchAtLogin.setEnabled(config.settings.launchAtLogin)
        let rulesSig = Self.appRulesSignature(config.rules)
        if rulesSig != appRulesSignature {
            appRulesSignature = rulesSig
            appRuleFramesApplied.removeAll()
        }
        reapplyAppRulesToAllWindows()
        refreshStatusItem()
        if quake.isVisible, let mon = primaryMonitor() {
            let frame: Rect
            if let qid = quake.windowID {
                frame = lastFrames[qid] ?? quake.visibleFrame(settings: config.settings.quake, monitor: mon)
            } else {
                frame = quake.visibleFrame(settings: config.settings.quake, monitor: mon)
            }
            quake.refreshBlur(settings: config.settings.quake, monitor: mon, frame: frame)
        }
        if notepad.isVisible, let mon = primaryMonitor() {
            let settings = config.settings.notepad
            let visible = notepad.panelFrame(settings: settings, monitor: mon, visible: true)
            notepad.refreshLayout(settings: settings, monitor: mon, visible: true, frame: visible)
        }
        // Re-apply frames so gap/outerGap/layout style changes take effect immediately.
        relayout(animated: false)
        refreshChrome()
    }

    var lastStatusLabel: String?

    var lastStatusLength: CGFloat = -1


    var lastRebalanceAt: [String: Date] = [:]

    let rebalanceDebounce: TimeInterval = 0.2


    var snappingWorkspaces: Set<String> = []

    var lastSnapSignature: [String: String] = [:]

    var gestureAccX: Double = 0

    var gestureAccY: Double = 0

    var gestureDiscreteFired = false

    var gestureActiveFingers: Int = 2

    var gestureDidContinuousScroll = false

    let gestureDiscreteThreshold: Double = 40

    var isGestureScrolling = false

    var gestureScrollIdleWorkItem: DispatchWorkItem?

    var gestureInertiaWorkItem: DispatchWorkItem?

    var gesturePanVelocity: Double = 0

    var gesturePanSampleAt: CFAbsoluteTime = 0

    var gesturePanKind: GesturePanKind = .columns

    var stackScrollAcc: Double = 0

    enum GesturePanKind {
        case columns
        case stack
    }

    var isColumnPanActive: Bool {
        isGestureScrolling || gestureDidContinuousScroll
    }

    var chromeRefreshWorkItem: DispatchWorkItem?


}

/// NSEvent monitors without capturing MainActor self.
final class AppKitEventMonitorBridge: @unchecked Sendable {
    let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func installGlobal(matching mask: NSEvent.EventTypeMask) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.handler()
            }
        }
    }

    func installLocal(matching mask: NSEvent.EventTypeMask) -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            Task { @MainActor in
                self.handler()
            }
            return event
        }
    }
}

/// Status item click target (nonisolated).
final class StatusItemClickBridge: NSObject {
    let onClick: (NSStatusBarButton) -> Void

    init(onClick: @escaping (NSStatusBarButton) -> Void) {
        self.onClick = onClick
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        onClick(sender)
    }
}


// MARK: - Shared static helpers

extension WindowManager {
    static func normalizedWindowTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\u{200e}", with: "")
            .replacingOccurrences(of: "\u{200f}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func titlesLooselyMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let al = a.lowercased()
        let bl = b.lowercased()
        if al.contains(bl) || bl.contains(al) { return true }
        // Shared significant prefix (tab titles that grow/shrink).
        let prefix = zip(al, bl).prefix(while: { $0 == $1 }).count
        return prefix >= 12
    }

    static func isPendingQuakeCandidate(
        window: ManagedWindow,
        pendingBundleID: String?,
        quakeWindowID: WindowID?,
        alreadyKnown: Set<WindowID>
    ) -> Bool {
        guard quakeWindowID == nil, let pendingBundleID, !pendingBundleID.isEmpty else { return false }
        if alreadyKnown.contains(window.id) { return false }
        if window.bundleID == pendingBundleID { return true }
        // First AX frames sometimes omit bundleID — fall back to app name.
        let bid = window.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bid.isEmpty {
            return appNameMatchesQuakeBundle(window.appName, bundleID: pendingBundleID)
        }
        return false
    }

    static func appNameMatchesQuakeBundle(_ appName: String, bundleID: String) -> Bool {
        let name = appName.lowercased()
        switch bundleID {
        case "com.apple.Terminal":
            return name.contains("terminal")
        case "com.mitchellh.ghostty":
            return name.contains("ghostty")
        default:
            return false
        }
    }

    static func appRulesSignature(_ rules: [AppRule]) -> String {
        rules.map {
            "\($0.bundleID ?? "")|\($0.appName ?? "")|\($0.mode.rawValue)|\($0.workspace ?? "")|\($0.monitorIndex.map(String.init) ?? "")|\($0.width ?? 0)|\($0.height ?? 0)|\($0.x ?? 0)|\($0.y ?? 0)"
        }.joined(separator: ";")
    }
}
