import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC

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
    private let capture = CaptureController()
    private let colorPalette = ColorPaletteController()

    private var engine = LayoutEngineRouter()
    private var windowsByID: [WindowID: ManagedWindow] = [:]
    private var lastFrames: [WindowID: Rect] = [:]
    private var primaryMonitorID: CGDirectDisplayID = 0
    private var mouseMonitor: Any?
    /// FFM NSEvent bridge (no MainActor capture in the callback).
    private var mouseMoveEventBridge: AppKitEventMonitorBridge?
    private var ffmWorkItem: DispatchWorkItem?
    private var ffmLastRun = Date.distantPast
    private var quakeClickMonitor: Any?
    private var quakeClickLocalMonitor: Any?
    /// Overlay dismiss NSEvent bridge.
    private var quakeClickEventBridge: AppKitEventMonitorBridge?
    private var suppressQuakeDismissUntil = Date.distantPast
    private var suppressNotepadDismissUntil = Date.distantPast
    private enum OverlayFocusTarget { case quake, notepad }
    private var preferredOverlayFocus: OverlayFocusTarget?

    private var overlaysCaptureFocus: Bool {
        quake.isVisible || notepad.isVisible
    }
    private var statusItem: NSStatusItem?
    private var statusItemClickBridge: StatusItemClickBridge?
    private var statusMarquee = StatusMarqueeController()
    private var focusSourceIsMouse = false
    private var floatingOverrides: Set<WindowID> = []
    /// Last window focused via Accessibility (may be float / not in columns).
    private var axFocusedWindowID: WindowID?
    /// Sticky window → workspace assignment (survives AX rescans).
    private var windowWorkspace: [WindowID: String] = [:]
    /// Soft-removed windows (AX flicker) — sticky kept until confirmed gone.
    private var missingScanCounts: [WindowID: Int] = [:]
    /// When we first saw a window — avoids ejecting brand-new tiles on the first AX blip.
    private var windowFirstTrackedAt: [WindowID: Date] = [:]
    private let newWindowColumnGrace: TimeInterval = 2.0
    private let floatRevealGrace: TimeInterval = 3.0
    /// Float windows on the active home must not be parked/minimized while opening or focused.
    private var forcedFloatVisibleUntil: [WindowID: Date] = [:]
    /// After a column is removed, keep re-applying tile frames until AX accepts the wider rect.
    private var forceTileExpandUntil: [String: Date] = [:]
    private let structuralTileExpandDuration: TimeInterval = 2.5
    /// While true, ingest must not reassign windows to the active workspace.
    private var suppressIngestReassignUntil = Date.distantPast
    /// Explicit move/send — keep tiled until AX settles (ingest must not re-float).
    private var forcedTiledUntil: [WindowID: Date] = [:]
    /// Bar menu + hotkey often fire twice within one tick — ignore the duplicate.
    private var lastMoveDedupe: (WindowID, String, Date)?
    /// Key repeat / double hotkey on tile move (merge then immediate peel).
    private var lastTileMoveDedupe: (String, String, Date)?
    /// Saved on-screen frames before parking (preserves size across workspace switches).
    private var savedFrames: [WindowID: Rect] = [:]
    /// Coalesce ingest→relayout storms from AX.
    private var ingestRelayoutWorkItem: DispatchWorkItem?
    /// Debounce rapid AX scan bursts before running full ingest.
    private var ingestDebounceWorkItem: DispatchWorkItem?
    private var pendingIngestWindows: [ManagedWindow]?
    private let ingestDebounceInterval: TimeInterval = 0.065
    /// Coalesce per-workspace rebalance after column heal.
    private var rebalanceWorkItems: [String: DispatchWorkItem] = [:]
    /// O(1) token → WindowID for restore/heal during AX churn.
    private var tokenByWindowToken: [String: WindowID] = [:]
    /// Skip redundant visibility apply when target set unchanged.
    private var lastVisibilitySignature: String?
    /// One structural heal per layout pass (ingest + visibility must not double-run).
    private var structuralHealDoneThisPass = false
    /// Debounce AX Moved/Resized → re-assert tiled frames.
    private var geometryEnforceWorkItem: DispatchWorkItem?
    /// Window IDs waiting for geometry enforce (must not drop when a newer event replaces the work item).
    private var geometryEnforcePending: Set<WindowID> = []
    /// Ignore AX Moved/Resized echoes right after programmatic stack/column layout.
    private var suppressGeometryEnforceUntil = Date.distantPast
    private var isApplyingVisibility = false
    /// If a relayout arrives while one is in flight, run it once after (never drop).
    private var pendingVisibilityAnimated: Bool?
    /// Persisted last-active workspaces + sticky assignments across launches.
    private let runtimeState = RuntimeStateStore()
    /// First ingest after launch uses bootstrap defaults (rules → sticky → last/1).
    private var isBootstrapping = true
    private var layoutRecoveryWorkItem: DispatchWorkItem?
    private var layoutRecoveryAttempts = 0
    private let maxLayoutRecoveryAttempts = 5
    /// Ignore AX focus that would bounce back to the previous workspace after a switch.
    private var suppressWorkspaceFollowUntil = Date.distantPast
    /// Bumps on every workspace switch so delayed settle tasks don't use a stale snapshot.
    private var workspaceSwitchGeneration: UInt64 = 0
    /// Bumps on every visibility apply so delayed leak-sweeps don't repark after a fast switch.
    private var visibilityApplyGeneration: UInt64 = 0
    private var systemObservers: [NSObjectProtocol] = []
    private var resumeRecoveryWorkItem: DispatchWorkItem?
    private var resumeRecoveryWorkItems: [DispatchWorkItem] = []
    /// After sleep, allow one recovery when the app becomes active (AX often lags behind wake).
    private var resumeRecoveryEligibleUntil = Date.distantPast
    /// True while staggered wake recovery is running — block column eject / disk overwrite.
    private var isResumeRecovering = false
    /// Update quit already flushed layouts — skip restoreAllOnscreen so we don't scramble frames.
    private var skipRestoreOnStopForUpdate = false
    /// After launch/update, avoid dumping unmatched windows onto the active workspace.
    private var postLaunchLayoutGraceUntil = Date.distantPast
    /// Snapshot frozen at willSleep so wake can restore even if in-memory columns drifted.
    private var preSleepLayoutFingerprint: String?
    /// Cached per visibility pass — layoutExcluded hammered AX and caused relayout storms.
    private var layoutExcludedCache: [String: Set<WindowID>] = [:]
    private var minimizedCache: [WindowID: Bool] = [:]
    private var visibilityOrphanPasses = 0
    private let maxVisibilityOrphanPasses = 1
    /// Workspace switch: always re-apply computed stack frames (skip isSettled).
    private var visibilityForceReveal = false
    /// While true, visibility refresh queued while quake/notepad blocked layout passes.
    private var visibilityDeferredWhileOverlay = false
    private var gesturesPausedForOverlay = false
    /// App-rule fixed frames already applied (avoid reveal/hide loops from repeated ingest).
    private var appRuleFramesApplied: Set<WindowID> = []
    private var forceAppRuleFrameApply = false
    private var appRulesSignature = ""

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
        PluginManager.shared.reloadFromSettings()

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

    /// Open System Settings panes + optional Screen Recording request.
    public func showPermissionsHelp() {
        let snap = Permissions.snapshot()
        if !snap.accessibility { Permissions.requestAccessibility() }
        if !snap.inputMonitoring { Permissions.requestInputMonitoring() }
        if !snap.screenRecording { Permissions.requestScreenRecording() }
        let alert = NSAlert()
        alert.messageText = "ALWM Permissions"
        alert.informativeText = """
        Required:
        • Accessibility — move/resize/focus windows
        • Input Monitoring — global hotkeys and trackpad gestures

        Optional:
        • Screen Recording — not required for tiling

        After toggling permissions in System Settings, quit and reopen ALWM.
        """
        alert.addButton(withTitle: "Open Accessibility")
        alert.addButton(withTitle: "Open Input Monitoring")
        alert.addButton(withTitle: "Open Screen Recording")
        alert.addButton(withTitle: "OK")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: Permissions.openAccessibilitySettings()
        case .alertSecondButtonReturn: Permissions.openInputMonitoringSettings()
        case .alertThirdButtonReturn: Permissions.openScreenRecordingSettings()
        default: break
        }
        if snap.requiredGranted {
            mutateSettings { $0.onboardingCompleted = true }
        }
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

    private func applyConfig(_ config: AlwmConfig) {
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

    private func applyAppearanceTheme(_ theme: AppTheme) {
        switch theme {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func syncWorkspacesToMonitors() {
        workspaces.configure(definitions: configStore.config.workspaces, monitors: monitors.monitors)
        primaryMonitorID = monitors.monitors.first?.id ?? 0
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: statusMarquee.preferredStatusLength)
        let clickBridge = StatusItemClickBridge { [weak self] button in
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
                self.statusPopover.toggle(relativeTo: button)
            }
        }
        statusItemClickBridge = clickBridge
        if let button = item.button {
            button.target = clickBridge
            button.action = #selector(StatusItemClickBridge.clicked(_:))
            button.sendAction(on: [.leftMouseUp])
            button.setButtonType(.momentaryLight)
            button.isEnabled = true
            button.appearsDisabled = false
            statusMarquee.attach(to: button)
        }
        statusItem = item

        statusPopover.onToggleFocusFollowsMouse = { [weak self] in
            self?.mutateSettings { $0.focusFollowsMouse.toggle() }
        }
        statusPopover.onToggleBorders = { [weak self] in
            self?.mutateSettings { $0.borders.enabled.toggle() }
        }
        statusPopover.onToggleWorkspaceBar = { [weak self] in
            self?.mutateSettings { $0.workspaceBar.enabled.toggle() }
        }
        statusPopover.onTogglePreventSleep = { [weak self] in
            self?.mutateSettings { $0.preventDisplaySleep.toggle() }
        }
        statusPopover.onOpenSettings = { [weak self] in self?.handleAction("settings.open") }
        statusPopover.onOpenPlugins = { [weak self] in self?.handleAction("settings.open.plugins") }
        statusPopover.onWhatsNew = { [weak self] in self?.menuWhatsNew() }
        statusPopover.onResetRuntime = { [weak self] in self?.resetRuntimeState() }
        statusPopover.onRestartClearing = { [weak self] in self?.menuRestartClearingState() }
        statusPopover.onPalette = { [weak self] in self?.handleAction("palette.toggle") }
        statusPopover.onQuake = { [weak self] in self?.handleAction("quake.toggle") }
        statusPopover.onNotepad = { [weak self] in self?.handleAction("notepad.toggle") }
        statusPopover.onOpenNote = { [weak self] id in self?.openNotepad(pageID: id) }
        statusPopover.onCaptureRegion = { [weak self] in self?.handleAction("capture.region") }
        statusPopover.onCaptureDisplay = { [weak self] in self?.handleAction("capture.display") }
        statusPopover.onCaptureRecordToggle = { [weak self] in self?.handleAction("capture.record.toggle") }
        statusPopover.onRelayout = { [weak self] in self?.handleAction("relayout") }
        statusPopover.onColorPalette = { [weak self] in
            self?.colorPalette.toggle(relativeTo: self?.statusItem?.button)
        }
        statusPopover.onQuit = { [weak self] in
            self?.stop()
            NSApp.terminate(nil)
        }

        refreshStatusItem()
    }

    private var lastStatusLabel: String?
    private var lastStatusLength: CGFloat = -1

    private func refreshStatusItem() {
        refreshStatusPopover()
        guard let item = statusItem else { return }
        let settings = configStore.config.settings
        let label = settings.showMenuBarStatusLabel ? statusBarWindowLabel() : ""
        // Skip marquee work when nothing visible changed (AX churn after capture was pegging CPU).
        if label == lastStatusLabel,
           abs(item.length - lastStatusLength) < 0.5 {
            return
        }
        lastStatusLabel = label
        statusMarquee.setText(label)
        let length = statusMarquee.preferredStatusLength
        if abs(item.length - length) > 0.5 {
            item.length = length
        }
        lastStatusLength = length
    }

    private func refreshStatusPopover() {
        let settings = configStore.config.settings
        statusPopover.update(
            focusFollowsMouse: settings.focusFollowsMouse,
            borders: settings.borders.enabled,
            workspaceBar: settings.workspaceBar.enabled,
            preventSleep: settings.preventDisplaySleep,
            developerMode: settings.developerMode,
            version: AlwmVersion.installed,
            isRecording: capture.isRecording,
            recentNotes: notepad.store.recentPreviews()
        )
    }

    /// Label for the menu-bar title: active workspace + a *visible* window on that workspace.
    /// Minimized / parked windows must not keep a long title occupying menu-bar space.
    private func statusBarWindowLabel() -> String {
        let mon = monitorUnderMouse() ?? primaryMonitor()
        let wsName: String = {
            guard let mon, let ws = workspaces.activeWorkspace(for: mon.id) else { return "ALWM" }
            return ws.name.isEmpty ? ws.id : ws.name
        }()
        if let win = statusBarFocusedWindow() {
            let live = ax.currentTitle(of: win.id)
                ?? win.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = live.trimmingCharacters(in: .whitespacesAndNewlines)
            let app = win.appName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return "\(wsName) – \(title)" }
            if !app.isEmpty { return "\(wsName) – \(app)" }
        }
        // No visible window: compact label (workspace id only) so we don't reserve title width.
        return wsName
    }

    private func statusBarFocusedWindow() -> ManagedWindow? {
        let mon = monitorUnderMouse() ?? primaryMonitor()
        guard let mon, let ws = workspaces.activeWorkspace(for: mon.id) else { return nil }
        let monitorFrames = monitors.monitors.map(\.frame)

        func isVisibleOnScreen(_ id: WindowID, _ win: ManagedWindow) -> Bool {
            if ax.isMinimized(id) { return false }
            let frame = ax.currentFrame(of: id) ?? win.frame
            return OffscreenParking.isOnAnyMonitor(frame, monitors: monitorFrames)
        }

        if let fid = ws.focusedWindowID,
           let win = windowsByID[fid],
           !win.isIgnored,
           windowIsOnActiveWorkspace(fid, monitor: mon),
           isVisibleOnScreen(fid, win) {
            return win
        }

        if let axID = axFocusedWindowID ?? ax.frontmostFocusedWindowID(),
           let win = windowsByID[axID],
           !win.isIgnored,
           windowIsOnActiveWorkspace(axID, monitor: mon),
           isVisibleOnScreen(axID, win) {
            return win
        }

        for col in ws.columns {
            for id in col.windows {
                if let win = windowsByID[id], !win.isIgnored, isVisibleOnScreen(id, win) {
                    return win
                }
            }
        }
        return nil
    }

    private func windowIsOnActiveWorkspace(_ id: WindowID, monitor: MonitorInfo) -> Bool {
        guard let activeID = workspaces.activeWorkspaceByMonitor[monitor.id] else { return false }
        if workspaces.workspaceID(containing: id) == activeID { return true }
        return windowWorkspace[id] == activeID
    }

    private func statusItemScreenFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let inWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    private func workspaceName(for windowID: WindowID) -> String {
        let wsID = windowWorkspace[windowID]
            ?? workspaces.workspaceID(containing: windowID)
            ?? {
                guard let mon = monitorUnderMouse() ?? primaryMonitor() else { return nil }
                return workspaces.activeWorkspaceByMonitor[mon.id]
            }()
        guard let wsID, let ws = workspaces.workspaces[wsID] else { return "—" }
        return ws.name.isEmpty ? ws.id : ws.name
    }

    private func monitorUnderMouse() -> MonitorInfo? {
        let p = NSEvent.mouseLocation
        let mainH = Double(NSScreen.screens.first?.frame.height ?? 0)
        // Cocoa bottom-left → AX top-left used by MonitorStore frames.
        let axY = mainH - Double(p.y)
        return monitors.monitorContaining(pointX: Double(p.x), pointY: axY)
    }

    private func mutateSettings(_ body: (inout LayoutSettings) -> Void) {
        var config = configStore.config
        body(&config.settings)
        ConfigWriter.write(config)
        configStore.replaceConfig(config)
        applyConfig(config)
        relayout(animated: true)
        refreshChrome()
    }

    @objc func menuWhatsNew() {
        statusPopover.close()
        let hosting = NSHostingController(rootView: WhatsNewView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "What's New"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 520, height: 440))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func menuRestartClearingState() {
        resetRuntimeState()
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    private func resetRuntimeState() {
        floatingOverrides.removeAll()
        lastFrames.removeAll()
        savedFrames.removeAll()
        windowWorkspace.removeAll()
        runtimeState.clear()
        isBootstrapping = true
        ax.scanAll()
        syncWorkspacesToMonitors()
        activateFirstWorkspaceOnAllMonitors()
        ingest(windows: ax.currentWindows)
        isBootstrapping = false
        persistRuntimeState()
        relayout(animated: false)
        refreshChrome()
        refreshStatusItem()
        NSLog("ALWM: runtime state reset")
    }

    private func restorePersistedWorkspaces() {
        for mon in monitors.monitors {
            let idx = workspaces.monitorIndex(of: mon.id, in: monitors.monitors) ?? 0
            let pool = workspaces.definitionsVisible(onMonitorIndex: idx).map(\.id)
            let lastByDisplay = runtimeState.lastWorkspace(for: mon.id)
            let lastGlobal = runtimeState.snapshot.lastWorkspace
            let pick = (lastByDisplay.flatMap { pool.contains($0) ? $0 : nil })
                ?? (lastGlobal.flatMap { pool.contains($0) ? $0 : nil })
                ?? pool.first(where: { workspaces.workspaces[$0] != nil })
            if let pick {
                workspaces.switchWorkspace(id: pick, on: mon.id, monitors: monitors.monitors, syncAllMonitors: false)
            }
        }
        primaryMonitorID = monitors.monitors.first?.id ?? primaryMonitorID
    }

    private func activateFirstWorkspaceOnAllMonitors() {
        for mon in monitors.monitors {
            let idx = workspaces.monitorIndex(of: mon.id, in: monitors.monitors) ?? 0
            guard let first = workspaces.definitionsVisible(onMonitorIndex: idx)
                .map(\.id)
                .first(where: { workspaces.workspaces[$0] != nil })
            else { continue }
            workspaces.switchWorkspace(id: first, on: mon.id, monitors: monitors.monitors, syncAllMonitors: false)
        }
        primaryMonitorID = monitors.monitors.first?.id ?? primaryMonitorID
    }

    private func firstWorkspaceID() -> String? {
        if workspaces.workspaces["1"] != nil { return "1" }
        return configStore.config.workspaces.first?.id ?? workspaces.workspaces.keys.sorted().first
    }

    private func loadStickyAssignmentsFromDisk() {
        for (token, wsID) in runtimeState.snapshot.windowWorkspace {
            guard workspaces.workspaces[wsID] != nil else { continue }
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let pid = Int32(parts[0]),
                  let winNum = Int(parts[1]) else { continue }
            windowWorkspace[WindowID(pid: pid, windowNumber: winNum)] = wsID
        }
    }

    /// Rebind sticky homes using layout WindowRefs when `pid:windowNumber` tokens went stale.
    private func rematchStickyFromSavedLayouts() {
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

    /// Sync flush before an in-place update quit — must not be skipped by bootstrap/resume guards.
    private func persistRuntimeStateBeforeUpdate() {
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

    private func persistRuntimeState(forceWorkspaceLayouts: Set<String> = []) {
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

    /// Write one workspace column tree to disk (optional force skips shrink guards).
    private func writeWorkspaceLayoutSnapshot(wsID: String, ws: WorkspaceState, force: Bool = false) {
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

    /// When only one tiled window of a bundle is saved, remember its workspace for token churn.
    private func syncBundleWorkspaceFromLayouts() {
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

    private func savedBundleInstanceCount(_ bundleID: String) -> Int {
        runtimeState.snapshot.workspaceLayouts.values.reduce(0) { partial, layout in
            partial + (layout.columns.flatMap(\.windows) + layout.floating)
                .filter { $0.bundleID == bundleID }.count
        }
    }

    /// Live tracked windows for a bundle (optionally same PID). Soft-missing ghosts excluded.
    private func liveBundleInstanceCount(_ bundleID: String, pid: pid_t? = nil) -> Int {
        windowsByID.values.filter { win in
            guard win.bundleID == bundleID, !win.isIgnored else { return false }
            if let pid, win.id.pid != pid { return false }
            return missingScanCounts[win.id] == nil
        }.count
    }

    /// True only when both disk and live tracking agree this app has a single window.
    private func isSingleBundleInstance(_ bundleID: String, pid: pid_t? = nil) -> Bool {
        savedBundleInstanceCount(bundleID) <= 1 && liveBundleInstanceCount(bundleID, pid: pid) <= 1
    }

    /// Find the workspace a relaunched window belonged to (token churn / late AX ingest).
    private func savedHome(for win: ManagedWindow, id: WindowID) -> String? {
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

    private func refSlotTaken(
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

    private func windowMatchesSavedRef(_ win: ManagedWindow, ref: RuntimeStateStore.WindowRef) -> Bool {
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

    /// Sticky home for restore matching — never steal a window owned by another workspace.
    private func stickyHome(for id: WindowID) -> String? {
        if let sticky = windowWorkspace[id], workspaces.workspaces[sticky] != nil { return sticky }
        if let saved = runtimeState.assignment(for: id), workspaces.workspaces[saved] != nil { return saved }
        return nil
    }

    /// Match a saved window ref to a live window.
    /// Order: token → title(+fuzzy) → best unused same-bundle (snapshot order claims distinct windows).
    private func resolveLiveWindow(
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

    private static func normalizedWindowTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: "\u{200e}", with: "")
            .replacingOccurrences(of: "\u{200f}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func titlesLooselyMatch(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let al = a.lowercased()
        let bl = b.lowercased()
        if al.contains(bl) || bl.contains(al) { return true }
        // Shared significant prefix (tab titles that grow/shrink).
        let prefix = zip(al, bl).prefix(while: { $0 == $1 }).count
        return prefix >= 12
    }

    /// Re-apply saved column / float order + tile widths after windows have been ingested.
    private func restoreWorkspaceLayoutsFromDisk() {
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

    /// Switch-back: re-apply saved column order/widths for windows already on this workspace.
    /// Unlike full restore, never claims unassigned windows via fuzzy bundle match.
    private func refreshWorkspaceLayoutFromSnapshot(for wsID: String) {
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

    private func belongsToWorkspace(_ id: WindowID, _ wsID: String) -> Bool {
        if windowWorkspace[id] == wsID { return true }
        if runtimeState.assignment(for: id) == wsID { return true }
        if workspaces.workspaceID(containing: id) == wsID { return true }
        if stickyHome(for: id) == wsID { return true }
        return false
    }

    /// Match a saved ref only when the live window is already sticky to `workspaceID`.
    private func resolveAssignedLiveWindow(
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

    private func fillZeroColumnWidths(workspace: inout WorkspaceState, workspaceID: String) {
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

    private func monitorForWorkspaceLayout(_ workspaceID: String) -> MonitorInfo? {
        monitors.monitors.first(where: { workspaces.activeWorkspaceByMonitor[$0.id] == workspaceID })
            ?? workspaces.preferredMonitor(forWorkspace: workspaceID, monitors: monitors.monitors)
            ?? monitors.monitors.first
    }

    /// Fill zero slots; expand to fill when a column was removed, shrink only on overflow.
    private func syncColumnWidthsToUsable(workspace: inout WorkspaceState, workspaceID: String) {
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

    /// After a cross-workspace send, remaining columns on the source WS must grow into freed space.
    private var lastRebalanceAt: [String: Date] = [:]
    private let rebalanceDebounce: TimeInterval = 0.2

    private func rebalanceWorkspaceAfterWindowLeft(_ wsID: String, force: Bool = false) {
        if !force,
           let last = lastRebalanceAt[wsID],
           Date().timeIntervalSince(last) < rebalanceDebounce {
            return
        }
        lastRebalanceAt[wsID] = Date()
        snapWorkspaceTilesAfterColumnChange(wsID)
    }

    /// Debounce rebalance storms from heal/ingest (many ws events → one snap pass).
    private func scheduleRebalanceWorkspace(_ wsID: String, force: Bool = false) {
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

    private func markStructuralLayoutChange(_ wsID: String) {
        forceTileExpandUntil[wsID] = Date().addingTimeInterval(structuralTileExpandDuration)
    }

    private func shouldForceTileExpand(_ wsID: String) -> Bool {
        forceTileExpandUntil[wsID].map { Date() < $0 } ?? false
    }

    /// Column removed / rebalance — snap every remaining tile to the new column widths immediately.
    private var snappingWorkspaces: Set<String> = []
    private var lastSnapSignature: [String: String] = [:]

    /// Column membership only — widths drift during AX enforce and must not retrigger rebalance.
    private func structuralSnapSignature(for ws: WorkspaceState) -> String {
        ws.columns.map { col in
            col.windows.map(\.token).sorted().joined(separator: ",")
        }.joined(separator: "|")
    }

    private func snapWorkspaceTilesAfterColumnChange(_ wsID: String) {
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

    /// In-memory column geometry wins over disk when switching back (user resize must stick).
    private func mergeLiveColumnGeometry(from live: WorkspaceState, into columns: inout [Column]) {
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

    private func restoreWorkspaceLayout(for wsID: String) {
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

    private func restoreWorkspaceLayout(for wsID: String, used: inout Set<WindowID>) {
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
                if isQuakeOwned(id) || runtimeState.snapshot.quakeWindowToken == ref.token {
                    win.isFloating = true
                    win.isScratchpad = true
                    windowsByID[id] = win
                    floatingOverrides.insert(id)
                    quake.rebind(id)
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

    /// Resolve where a tiled window belongs.
    /// Rules (pinned workspace) → sticky *window* token → active / first.
    /// Never use per-bundle sticky — the same app may own windows on many workspaces.
    private func resolveTargetWorkspace(for win: ManagedWindow, on monitor: MonitorInfo) -> String? {
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

    private func bootstrapDefaultWorkspace(on monitor: MonitorInfo) -> String? {
        firstWorkspaceID()
    }

    private func assignWindow(
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

    /// Re-insert using saved column/row when available so switch/retile keeps tile order.
    @discardableResult
    private func placeWindowFromSnapshot(_ id: WindowID, into workspaceID: String, usable: Rect) -> Bool {
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

    /// Insert into the saved column index when row matching failed (keeps vertical stacks intact).
    @discardableResult
    private func placeWindowInSavedColumn(_ id: WindowID, into workspaceID: String, usable: Rect) -> Bool {
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

    /// Copy leafWeights from saved tokens onto live window tokens after AX churn.
    private func remappedLeafWeights(
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

    private func remapLeafWeight(
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

    /// Ensure a floating / scratchpad window has a home workspace for the ⌀ chip + hide/show.
    private func ensureFloatHome(_ id: WindowID, win: ManagedWindow) {
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

    /// Place any tracked window that fell out of every column / float home.
    private func adoptOrphanWindows(blockingReassign: Bool) {
        if blockingReassign { return }
        for (id, win) in windowsByID {
            guard !win.isIgnored, quake.windowID != id, !isQuakeOwned(id) else { continue }
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

    /// Main browser/app windows vs emoji/sticker/sheet popups (WhatsApp, etc.).
    private func looksLikeMainTiledWindow(_ frame: Rect, usable: Rect) -> Bool {
        let area = max(1, frame.width * frame.height)
        let usableArea = max(1, usable.width * usable.height)
        return area >= usableArea * 0.18
            || (frame.width >= usable.width * 0.4 && frame.height >= usable.height * 0.35)
    }

    private func usableAreaNear(_ frame: Rect) -> Rect {
        let mon = monitors.monitorContaining(pointX: frame.midX, pointY: frame.midY)
            ?? primaryMonitor()
            ?? monitors.monitors.first
        guard let mon else {
            return Rect(x: 0, y: 0, width: max(1, frame.width), height: max(1, frame.height))
        }
        return engine.usableArea(monitor: mon.layoutFrame)
    }

    /// Pull main windows that were wrongly marked float (AX / bad persist) back into columns.
    private func retileAccidentalFloats(forceClearOverrides: Bool = false) {
        let rules = configStore.config.rules
        for (id, win) in windowsByID {
            guard !win.isIgnored, quake.windowID != id, !isQuakeOwned(id), !win.isScratchpad else { continue }
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

    /// Quake scratchpad identity — live id or persisted token.
    private func isQuakeOwned(_ id: WindowID) -> Bool {
        if id == quake.windowID { return true }
        return runtimeState.snapshot.quakeWindowToken == id.token
    }

    /// Keep the Quake window as a sticky float forever (no tile column).
    private func enforceQuakeFloat() {
        // Rebind from persisted token after relaunch.
        if quake.windowID == nil, let token = runtimeState.snapshot.quakeWindowToken {
            if let id = windowsByID.keys.first(where: { $0.token == token }) {
                quake.rebind(id)
                NSLog("ALWM Quake: rebound from token %@", token)
            }
        }

        guard let id = quake.windowID, var win = windowsByID[id] else { return }
        win.isFloating = true
        win.isScratchpad = true
        windowsByID[id] = win
        floatingOverrides.insert(id)
        workspaces.removeWindowEverywhere(id)
        runtimeState.setQuakeWindowToken(id.token)
        ensureFloatHome(id, win: win)
    }

    /// While a Quake launch is in flight, never leave matching windows in tile columns.
    /// Returns true if any window was removed from a tile column (caller should sync-relayout).
    @discardableResult
    private func stripPendingQuakeFromColumns() -> Bool {
        guard quake.windowID == nil, let pending = quake.pendingAdoptBundleID else { return false }
        var stripped = false
        for (id, win) in windowsByID {
            // Only candidates already flagged for Quake — never yank a normal tiled Terminal.
            guard floatingOverrides.contains(id) || win.isScratchpad else { continue }
            let matchesBundle = win.bundleID == pending
            let matchesName = Self.appNameMatchesQuakeBundle(win.appName, bundleID: pending)
            guard matchesBundle || matchesName else { continue }
            if var updated = windowsByID[id] {
                updated.isFloating = true
                updated.isScratchpad = true
                windowsByID[id] = updated
            }
            floatingOverrides.insert(id)
            if workspaces.workspaceID(containing: id) != nil {
                workspaces.removeWindowEverywhere(id)
                stripped = true
            }
        }
        return stripped
    }

    /// True for the next Terminal/Ghostty window created while Quake is launching.
    private static func isPendingQuakeCandidate(
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

    private static func appNameMatchesQuakeBundle(_ appName: String, bundleID: String) -> Bool {
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

    /// Column slots win over transient AX float/dialog flags — never for app-rule floats.
    private func syncColumnTilesNotFloat() {
        let rules = configStore.config.rules
        for (id, var win) in windowsByID {
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

    /// Drop a soft-missing window from tile columns (closed vs park / AX blip).
    private func shouldEjectMissingFromColumns(_ id: WindowID, missingCount: Int) -> Bool {
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

    /// New windows: clear false AX float flags on *main* windows and ensure a column slot.
    /// Emoji/sticker/sheet popups stay floating — tiling them equal-splits the workspace.
    private func settleNewTiledWindows(_ ids: Set<WindowID>) {
        guard !ids.isEmpty else { return }
        let rules = configStore.config.rules
        for id in ids {
            guard var win = windowsByID[id], !win.isIgnored else { continue }
            if quake.windowID == id || isQuakeOwned(id) { continue }
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

    /// Keep `mode = "float"` app-rule windows out of columns (they steal vertical slots).
    @discardableResult
    private func enforceAppRuleFloats() -> Set<String> {
        let rules = configStore.config.rules
        var stripped: Set<String> = []
        for (id, win) in windowsByID {
            guard !win.isIgnored, AppRules.forcesFloat(rules: rules, window: win) else { continue }
            var floating = win
            floating.isFloating = true
            windowsByID[id] = floating
            forcedTiledUntil.removeValue(forKey: id)
            if let wsID = workspaces.workspaceID(containing: id) {
                stripped.insert(wsID)
                workspaces.removeWindowEverywhere(id)
            }
            ensureFloatHome(id, win: floating)
            if let home = windowWorkspace[id], isHomeActiveOnAnyMonitor(home) {
                markFloatRevealProtected(id)
            }
        }
        return stripped
    }

    /// Re-apply app rules to every tracked window (config reload / resume recovery).
    private func reapplyAppRulesToAllWindows() {
        let rules = configStore.config.rules
        guard !windowsByID.isEmpty else { return }

        for (id, win) in windowsByID {
            var applied = AppRules.apply(rules: rules, to: win)
            if isQuakeOwned(id) || quake.windowID == id {
                applied.isFloating = true
                applied.isScratchpad = true
                floatingOverrides.insert(id)
            } else if AppRules.forcesFloat(rules: rules, window: applied) {
                applied.isFloating = true
            } else if floatingOverrides.contains(id) {
                applied.isFloating = true
            } else if applied.isIgnored {
                applied.isFloating = false
            } else if workspaces.workspaceID(containing: id) != nil
                || windowWorkspace[id] != nil
                || runtimeState.assignment(for: id) != nil {
                applied.isFloating = false
            }
            windowsByID[id] = applied
        }

        enforceAppRuleFloats()

        for id in windowsByID.keys {
            applyAppRulePlacement(to: id)
        }
    }

    /// Apply rules immediately (Settings → Apply now).
    func applyAppRulesNow() {
        forceAppRuleFrameApply = true
        reapplyAppRulesToAllWindows()
        forceAppRuleFrameApply = false
        relayout(animated: true)
        refreshChrome()
        refreshStatusItem()
    }

    func runningAppsForRules() -> [AppRuleRunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
            .compactMap { app -> AppRuleRunningApp? in
                guard let bid = app.bundleIdentifier else { return nil }
                let name = app.localizedName ?? bid
                return AppRuleRunningApp(bundleID: bid, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func captureAppRuleGeometry(bundleID: String?) -> AppRuleCapturedGeometry? {
        guard let win = bestWindowForRuleCapture(bundleID: bundleID) else { return nil }
        let frame = ax.currentFrame(of: win.id) ?? win.frame
        let monitor = monitors.monitorContaining(pointX: frame.midX, pointY: frame.midY)
            ?? primaryMonitor()
        guard let monitor else { return nil }
        let idx = monitors.monitors.firstIndex(where: { $0.id == monitor.id }) ?? 0
        var geo = AppRules.geometry(from: frame, on: monitor, monitorIndex: idx)
        geo.workspace = authoritativeHome(for: win.id)
        geo.isFloating = win.isFloating || win.isScratchpad
        return geo
    }

    private func bestWindowForRuleCapture(bundleID: String?) -> ManagedWindow? {
        let bid = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bid, !bid.isEmpty {
            if let focused = ax.frontmostFocusedWindowID(),
               let front = windowsByID[focused],
               front.bundleID == bid,
               !front.isIgnored {
                return front
            }
            let matches = windowsByID.values.filter { $0.bundleID == bid && !$0.isIgnored }
            return matches.max(by: { a, b in
                let aa = a.frame.width * a.frame.height
                let bb = b.frame.width * b.frame.height
                return aa < bb
            })
        }
        if let focused = ax.frontmostFocusedWindowID(),
           let front = windowsByID[focused],
           !front.isIgnored {
            return front
        }
        return nil
    }

    private func monitorForAppRule(_ rule: AppRule, window: ManagedWindow) -> MonitorInfo? {
        if let idx = rule.monitorIndex, monitors.monitors.indices.contains(idx) {
            return monitors.monitors[idx]
        }
        if let ws = AppRules.preferredWorkspace(rules: configStore.config.rules, window: window),
           let mon = workspaces.preferredMonitor(forWorkspace: ws, monitors: monitors.monitors) {
            return mon
        }
        return monitors.monitorContaining(pointX: window.frame.midX, pointY: window.frame.midY)
            ?? primaryMonitor()
    }

    private func applyRuleFrame(_ frame: Rect, to id: WindowID) {
        let monitors = monitors.monitors.map(\.frame)
        if ax.isSettled(id: id, frame: frame, monitors: monitors) {
            lastFrames[id] = frame
            savedFrames[id] = frame
            return
        }
        ax.suppressNotifications(for: 0.2)
        ax.reveal(frame: frame, id: id)
        ax.applyFrameOnly(frame: frame, to: id)
        lastFrames[id] = frame
        savedFrames[id] = frame
    }

    private func applyAppRulePlacement(to id: WindowID) {
        guard let win = windowsByID[id], !win.isIgnored else { return }
        guard !isQuakeOwned(id), quake.windowID != id else { return }
        let rules = configStore.config.rules
        guard let rule = AppRules.matching(rules: rules, window: win) else { return }
        guard let monitor = monitorForAppRule(rule, window: win) else { return }

        if let preferred = AppRules.preferredWorkspace(rules: rules, window: win),
           workspaces.workspaces[preferred] != nil {
            if win.isTiled {
                if windowWorkspace[id] != preferred || workspaces.workspaceID(containing: id) != preferred {
                    assignWindow(id, to: preferred, on: monitor)
                }
            } else {
                windowWorkspace[id] = preferred
                runtimeState.setAssignment(preferred, for: id)
            }
        }

        let shouldApplyFrame = forceAppRuleFrameApply || !appRuleFramesApplied.contains(id)
        if shouldApplyFrame,
           win.isFloating || rule.mode == .float,
           let frame = AppRules.targetFrame(rule: rule, monitor: monitor, fallback: win.frame) {
            applyRuleFrame(frame, to: id)
            appRuleFramesApplied.insert(id)
            if var updated = windowsByID[id] {
                updated.frame = frame
                windowsByID[id] = updated
            }
        }
    }

    private static func appRulesSignature(_ rules: [AppRule]) -> String {
        rules.map {
            "\($0.bundleID ?? "")|\($0.appName ?? "")|\($0.mode.rawValue)|\($0.workspace ?? "")|\($0.monitorIndex.map(String.init) ?? "")|\($0.width ?? 0)|\($0.height ?? 0)|\($0.x ?? 0)|\($0.y ?? 0)"
        }.joined(separator: ";")
    }

    private func showOnboardingAlert() {
        let alert = NSAlert()
        alert.messageText = "Bem-vindo ao ALWM"
        alert.informativeText = """
        1. Conceda Acesso de Acessibilidade em Ajustes do Sistema → Privacidade e Segurança.
        2. Use Settings (⌥,) para tema, workspace bar, borders e hotkeys.
        3. Controle rápido pelo ícone na menu bar (Focus Follows Mouse, Borders, Workspace Bar).
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Abrir Ajustes do Sistema")
        alert.addButton(withTitle: "Continuar")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            AXTracker.requestTrust()
        }
        mutateSettings { $0.onboardingCompleted = true }
    }

    private func setupFocusFollowsMouse() {
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

    /// Click outside overlay panels → dismiss (quake terminal / notepad).
    private func setupOverlayClickOutside() {
        if let quakeClickMonitor {
            NSEvent.removeMonitor(quakeClickMonitor)
            self.quakeClickMonitor = nil
        }
        if let quakeClickLocalMonitor {
            NSEvent.removeMonitor(quakeClickLocalMonitor)
            self.quakeClickLocalMonitor = nil
        }
        quakeClickEventBridge = nil
        let settings = configStore.config.settings
        guard settings.quake.enabled || settings.notepad.enabled else { return }

        let bridge = AppKitEventMonitorBridge { [weak self] in
            self?.dismissOverlaysIfClickOutside()
        }
        quakeClickEventBridge = bridge
        quakeClickMonitor = bridge.installGlobal(matching: [.leftMouseDown, .rightMouseDown])
        quakeClickLocalMonitor = bridge.installLocal(matching: [.leftMouseDown, .rightMouseDown])
    }

    private func dismissOverlaysIfClickOutside() {
        dismissQuakeIfClickOutside()
        dismissNotepadIfClickOutside()
    }

    private func quakeHasKeyboardFocus() -> Bool {
        guard quake.isVisible, let qid = quake.windowID else { return false }
        if axFocusedWindowID == qid || ax.frontmostFocusedWindowID() == qid { return true }
        let configured = configStore.config.settings.quake.bundleID
        let resolved = QuakeTerminalController.resolveBundleID(configured: configured)
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == resolved { return true }
        return false
    }

    private func dismissNotepadIfClickOutside() {
        guard configStore.config.settings.notepad.enabled else { return }
        guard notepad.isVisible else { return }
        guard Date() >= suppressNotepadDismissUntil else { return }
        guard let monitor = monitorForAction() ?? primaryMonitor() else { return }
        let settings = configStore.config.settings.notepad
        let loc = NSEvent.mouseLocation
        if notepad.containsClick(at: loc, settings: settings, monitor: monitor) {
            preferredOverlayFocus = .notepad
            return
        }
        dismissNotepad(on: monitor)
    }

    private func updateOverlayInputMode() {
        let overlayNow = overlaysCaptureFocus
        hotkeys.setOverlayKeyboardCapture(overlayNow)

        if overlayNow {
            if configStore.config.settings.gestures.enabled, !gesturesPausedForOverlay {
                gesturesPausedForOverlay = true
                gestures.stop()
            }
        } else {
            if gesturesPausedForOverlay {
                gesturesPausedForOverlay = false
                setupGestures()
            }
            if visibilityDeferredWhileOverlay {
                visibilityDeferredWhileOverlay = false
                applyWorkspaceVisibility(animated: false)
            }
        }
    }

    private func dismissNotepad(on monitor: MonitorInfo) {
        guard notepad.isVisible else { return }
        notepad.hide(settings: configStore.config.settings.notepad, monitor: monitor)
        updateOverlayInputMode()
    }

    private func toggleNotepad(monitor: MonitorInfo) {
        let settings = configStore.config.settings.notepad
        if notepad.isVisible {
            dismissNotepad(on: monitor)
        } else {
            notepad.show(settings: settings, monitor: monitor)
            preferredOverlayFocus = .notepad
            suppressNotepadDismissUntil = Date().addingTimeInterval(0.5)
        }
        updateOverlayInputMode()
    }

    private func openNotepad(pageID: UUID) {
        guard let monitor = monitorForAction() ?? primaryMonitor() else { return }
        let settings = configStore.config.settings.notepad
        notepad.open(pageID: pageID, settings: settings, monitor: monitor)
        preferredOverlayFocus = .notepad
        suppressNotepadDismissUntil = Date().addingTimeInterval(0.5)
        updateOverlayInputMode()
    }

    private func openNewNotepad(monitor: MonitorInfo) {
        let settings = configStore.config.settings.notepad
        notepad.openNew(settings: settings, monitor: monitor)
        preferredOverlayFocus = .notepad
        suppressNotepadDismissUntil = Date().addingTimeInterval(0.5)
        updateOverlayInputMode()
    }

    private func dismissQuakeIfClickOutside() {
        guard configStore.config.settings.quake.enabled else { return }
        guard quake.isVisible, let qid = quake.windowID else { return }
        guard Date() >= suppressQuakeDismissUntil else { return }

        let loc = NSEvent.mouseLocation
        let mainHeight = Double(NSScreen.screens.first?.frame.height ?? loc.y)
        let axX = Double(loc.x)
        let axY = mainHeight - Double(loc.y)
        let frame = ax.currentFrame(of: qid)
            ?? lastFrames[qid]
            ?? (primaryMonitor().map { quake.visibleFrame(settings: configStore.config.settings.quake, monitor: $0) })
        if let frame, frame.contains(pointX: axX, pointY: axY) {
            preferredOverlayFocus = .quake
            return
        }
        dismissQuake()
    }

    private func dismissQuake() {
        guard quake.isVisible else { return }
        guard let monitor = monitorForAction() ?? primaryMonitor() else { return }
        let settings = configStore.config.settings.quake
        quake.dismiss(
            settings: settings,
            monitor: monitor,
            applyFrame: { @Sendable [weak self] id, frame in
                Task { @MainActor in
                    guard let self else { return }
                    self.ax.parkAndHide(frame: frame, id: id, monitors: self.monitors.monitors.map(\.frame))
                    self.lastFrames[id] = frame
                }
            },
            focusTiled: { @Sendable [weak self] in
                Task { @MainActor in
                    guard let self, !self.overlaysCaptureFocus else { return }
                    guard let mon = self.primaryMonitor() else { return }
                    if let focused = self.workspaces.activeWorkspace(for: mon.id)?.focusedWindowID {
                        self.ax.focus(focused)
                    }
                }
            }
        )
        if let qid = quake.windowID {
            let hidden = quake.hiddenFrame(settings: settings, monitor: monitor)
            ax.parkAndHide(frame: hidden, id: qid, monitors: monitors.monitors.map(\.frame))
            lastFrames[qid] = hidden
        }
        preferredOverlayFocus = nil
        updateOverlayInputMode()
        DispatchQueue.main.async { [weak self] in
            self?.applyWorkspaceVisibility(animated: false)
            self?.refreshChrome()
        }
    }

    private func handleQuakeWindowClosed() {
        let closedID = quake.windowID
        quake.clearAfterUserClose()
        runtimeState.setQuakeWindowToken(nil)
        preferredOverlayFocus = nil
        if let closedID {
            windowsByID.removeValue(forKey: closedID)
            windowWorkspace.removeValue(forKey: closedID)
            floatingOverrides.remove(closedID)
            lastFrames.removeValue(forKey: closedID)
            savedFrames.removeValue(forKey: closedID)
            missingScanCounts.removeValue(forKey: closedID)
            workspaces.removeWindowEverywhere(closedID)
            runtimeState.setAssignment(nil, for: closedID)
        }
        ingestRelayoutWorkItem?.cancel()
        suppressQuakeDismissUntil = Date().addingTimeInterval(0.4)
        updateOverlayInputMode()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyFluidLayout(animated: false)
            self.refreshChrome()
        }
    }

    /// Accumulated swipe deltas for discrete gesture bindings.
    private var gestureAccX: Double = 0
    private var gestureAccY: Double = 0
    private var gestureDiscreteFired = false
    private var gestureActiveFingers: Int = 2
    private var gestureDidContinuousScroll = false
    private let gestureDiscreteThreshold: Double = 40
    /// True while a continuous column-scroll gesture is in flight (skip AX enforce storms).
    private var isGestureScrolling = false
    private var gestureScrollIdleWorkItem: DispatchWorkItem?
    private var gestureInertiaWorkItem: DispatchWorkItem?
    /// EMA of pan velocity (points/sec) for Niri-like inertia on finger lift.
    private var gesturePanVelocity: Double = 0
    private var gesturePanSampleAt: CFAbsoluteTime = 0
    private var gesturePanKind: GesturePanKind = .columns
    private var stackScrollAcc: Double = 0

    private enum GesturePanKind {
        case columns
        case stack
    }

    private func setupGestures() {
        gestures.stop()
        gestureAccX = 0
        gestureAccY = 0
        gestureDiscreteFired = false
        gestureDidContinuousScroll = false
        gesturePanVelocity = 0
        stackScrollAcc = 0
        gestureScrollIdleWorkItem?.cancel()
        gestureInertiaWorkItem?.cancel()
        guard configStore.config.settings.gestures.enabled else { return }
        gestures.onSignal = { [weak self] signal in
            self?.handleGestureSignal(signal)
        }
        gestures.start()
    }

    private func handleGestureSignal(_ signal: GestureScrollMonitor.Signal) {
        // Settings, plugin panels, palette, quake/notepad — never hijack trackpad/mouse scroll.
        if chromeBlocksFocusFollowsMouse() { return }
        let g = configStore.config.settings.gestures
        guard g.enabled else { return }
        let invert = g.invertScroll ? -1.0 : 1.0
        let dx = signal.dx * invert
        let dy = signal.dy * invert
        let fingers = signal.fingers
        if fingers != gestureActiveFingers {
            gestureActiveFingers = fingers
            gestureAccX = 0
            gestureAccY = 0
            gestureDiscreteFired = false
            stackScrollAcc = 0
        }

        let bindings = g.bindings.filter { $0.enabled && $0.fingers == fingers }
        let continuousBindings = g.bindings.filter {
            $0.enabled && $0.direction.isContinuous
                && ($0.action == "scroll.columns" || $0.action == "scroll.stack")
        }
        let hasContinuousH = bindings.contains {
            $0.direction == .horizontal && ($0.action == "scroll.columns" || $0.action == "scroll.stack")
        } || (gestureDidContinuousScroll && gesturePanKind == .columns
              && continuousBindings.contains { $0.direction == .horizontal })
        let hasContinuousV = bindings.contains {
            $0.direction == .vertical && ($0.action == "scroll.columns" || $0.action == "scroll.stack")
        } || (gestureDidContinuousScroll && gesturePanKind == .stack
              && continuousBindings.contains { $0.direction == .vertical })
        let hasDiscrete = bindings.contains { !$0.direction.isContinuous }

        // Prefer continuous pan: never fire discrete focus/workspace mid-scroll.
        if hasContinuousH || hasContinuousV || gestureDidContinuousScroll {
            if signal.ended {
                if gestureDidContinuousScroll {
                    scheduleGestureScrollFinish()
                }
                return
            }
            // Base gain so Magic Trackpad feels closer to Niri even at factor≈1.
            let gain = g.swipeScrollFactor * 1.85
            if hasContinuousH, abs(dx) >= abs(dy), abs(dx) > 0.05 {
                gesturePanKind = .columns
                applyContinuousColumnScroll(delta: dx * gain, fromFinger: true)
            } else if hasContinuousV, abs(dy) > abs(dx), abs(dy) > 0.05 {
                // Vertical continuous = scroll the focused column stack (not viewOffset).
                gesturePanKind = .stack
                applyContinuousStackScroll(delta: dy * gain, fromFinger: true)
            }
            return
        }

        // Discrete swipe (ended with a clear direction).
        if signal.ended, hasDiscrete, !gestureDiscreteFired {
            gestureAccX += dx
            gestureAccY += dy
            let threshold = gestureDiscreteThreshold
            if let direction = dominantDiscreteDirection(accX: gestureAccX, accY: gestureAccY, threshold: threshold),
               let binding = bindings.first(where: { $0.direction == direction && !$0.direction.isContinuous }) {
                gestureDiscreteFired = true
                NSLog("ALWM gesture: %@ (fingers=%d)", binding.action, fingers)
                handleAction(binding.action)
                gestureAccX = 0
                gestureAccY = 0
                gestureDiscreteFired = false
                return
            }
        }

        if hasDiscrete {
            gestureAccX += dx
            gestureAccY += dy
            if !gestureDiscreteFired {
                if let direction = dominantDiscreteDirection(accX: gestureAccX, accY: gestureAccY),
                   let binding = bindings.first(where: { $0.direction == direction && !$0.direction.isContinuous }) {
                    gestureDiscreteFired = true
                    NSLog("ALWM gesture: %@ (fingers=%d)", binding.action, fingers)
                    handleAction(binding.action)
                }
            }
        }

        if signal.ended {
            if !gestureDiscreteFired, hasDiscrete {
                if let direction = dominantDiscreteDirection(accX: gestureAccX, accY: gestureAccY, threshold: 50),
                   let binding = bindings.first(where: { $0.direction == direction && !$0.direction.isContinuous }) {
                    handleAction(binding.action)
                }
            }
            gestureAccX = 0
            gestureAccY = 0
            gestureDiscreteFired = false
        }
    }

    private func dominantDiscreteDirection(
        accX: Double,
        accY: Double,
        threshold: Double? = nil
    ) -> GestureDirection? {
        let t = threshold ?? gestureDiscreteThreshold
        if abs(accX) >= abs(accY), abs(accX) >= t {
            return accX > 0 ? .right : .left
        }
        if abs(accY) > abs(accX), abs(accY) >= t {
            return accY > 0 ? .down : .up
        }
        return nil
    }

    private func notePanVelocity(_ delta: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(1.0 / 240.0, now - gesturePanSampleAt)
        let instant = delta / dt
        gesturePanVelocity = gesturePanSampleAt == 0
            ? instant
            : gesturePanVelocity * 0.55 + instant * 0.45
        gesturePanSampleAt = now
    }

    /// Horizontal column strip pan — fast AX apply only (no full visibility/park sweep).
    private func applyContinuousColumnScroll(delta: Double, fromFinger: Bool) {
        guard let monitor = primaryMonitor() else { return }
        isGestureScrolling = true
        gestureDidContinuousScroll = true
        if fromFinger {
            notePanVelocity(delta)
            scheduleGestureScrollFinish()
        }
        let usable = engine.usableArea(monitor: monitor.layoutFrame)
        mutateActive(monitor.id) {
            let maxO = engine.maxViewOffset(workspace: $0, usable: usable)
            engine.scroll(by: delta, workspace: &$0, maxOffset: maxO)
        }
        ax.suppressNotifications(for: 0.18)
        applyActiveWorkspaceFramesFast(on: monitor)
    }

    /// Vertical stack pan inside the focused column — advances focus with velocity-scaled steps.
    private func applyContinuousStackScroll(delta: Double, fromFinger: Bool) {
        guard let monitor = primaryMonitor() else { return }
        isGestureScrolling = true
        gestureDidContinuousScroll = true
        if fromFinger {
            notePanVelocity(delta)
            scheduleGestureScrollFinish()
        }
        // Lower threshold + factor = quicker flips through stacked windows (Niri-like).
        let step = max(28.0, 72.0 / max(0.5, configStore.config.settings.gestures.swipeScrollFactor))
        stackScrollAcc += delta
        var changed = false
        while stackScrollAcc >= step {
            stackScrollAcc -= step
            mutateActive(monitor.id) {
                engine.focus(
                    .down,
                    workspace: &$0,
                    usable: engine.usableArea(monitor: monitor.layoutFrame),
                    windows: windowsByID,
                    monitor: monitor.layoutFrame
                )
            }
            changed = true
        }
        while stackScrollAcc <= -step {
            stackScrollAcc += step
            mutateActive(monitor.id) {
                engine.focus(
                    .up,
                    workspace: &$0,
                    usable: engine.usableArea(monitor: monitor.layoutFrame),
                    windows: windowsByID,
                    monitor: monitor.layoutFrame
                )
            }
            changed = true
        }
        guard changed else { return }
        ax.suppressNotifications(for: 0.18)
        applyActiveWorkspaceFramesFast(on: monitor)
        if let focused = workspaces.activeWorkspace(for: monitor.id)?.focusedWindowID {
            axFocusedWindowID = focused
            if !chromeBlocksFocusFollowsMouse() {
                ax.focus(focused)
            }
        }
    }

    /// Apply only the active workspace's computed frames — avoids park/leak sweeps mid-pan.
    private func applyActiveWorkspaceFramesFast(on monitor: MonitorInfo) {
        guard let wsID = workspaces.activeWorkspaceByMonitor[monitor.id],
              let ws = workspaces.workspaces[wsID]
        else { return }
        let assignments = engine.computeFrames(
            workspace: ws,
            windows: windowsByID,
            monitor: monitor.layoutFrame,
            active: true,
            stackExcluded: stackExcludedFromLayout(),
            layoutExcluded: layoutExcludedWindowIDs(for: wsID, monitor: monitor)
        )
        let monitorsFrames = monitors.monitors.map(\.frame)
        ax.withMutation {
            for a in assignments {
                guard windowsByID[a.windowID] != nil else { continue }
                let onScreen = OffscreenParking.isUsableOnscreenFrame(a.frame, monitors: monitorsFrames)
                if onScreen {
                    if ax.isMinimized(a.windowID) {
                        ax.setMinimized(false, id: a.windowID)
                    }
                    ax.applyFrameOnly(frame: a.frame, to: a.windowID)
                } else {
                    ax.parkOffscreen(frame: a.frame, id: a.windowID, monitors: monitorsFrames)
                }
                lastFrames[a.windowID] = a.frame
            }
        }
        refreshBorder()
    }

    /// End a continuous pan — run inertia then settle.
    private func finishContinuousColumnScroll() {
        gestureScrollIdleWorkItem?.cancel()
        gestureScrollIdleWorkItem = nil
        let velocity = gesturePanVelocity
        gesturePanVelocity = 0
        gesturePanSampleAt = 0
        // Flick → coast (Niri-like). Skip tiny residual motion.
        if abs(velocity) > 450 {
            startGestureInertia(velocity: velocity)
            return
        }
        settleContinuousGesture()
    }

    private func startGestureInertia(velocity: Double) {
        gestureInertiaWorkItem?.cancel()
        var v = velocity
        // Cap so a wild flick doesn't jump across the whole strip.
        v = min(max(v, -6_000), 6_000)
        func tick() {
            guard abs(v) > 180 else {
                settleContinuousGesture()
                return
            }
            let step = v * (1.0 / 60.0)
            v *= 0.90
            switch gesturePanKind {
            case .columns:
                applyContinuousColumnScroll(delta: step, fromFinger: false)
            case .stack:
                applyContinuousStackScroll(delta: step, fromFinger: false)
            }
            let work = DispatchWorkItem { tick() }
            gestureInertiaWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (1.0 / 60.0), execute: work)
        }
        tick()
    }

    private func settleContinuousGesture() {
        gestureInertiaWorkItem?.cancel()
        gestureInertiaWorkItem = nil
        isGestureScrolling = false
        gestureDidContinuousScroll = false
        gestureAccX = 0
        gestureAccY = 0
        stackScrollAcc = 0
        // Optional column snap after coast.
        if gesturePanKind == .columns, configStore.config.settings.gestures.scrollSnap,
           let monitor = primaryMonitor() {
            let usable = engine.usableArea(monitor: monitor.layoutFrame)
            mutateActive(monitor.id) {
                engine.snapScroll(workspace: &$0, usable: usable)
            }
        }
        applyFluidLayout(animated: false)
        refreshChrome()
    }

    private func snapGestureScroll() {
        // Legacy entry — settle with snap.
        gesturePanKind = .columns
        settleContinuousGesture()
    }

    /// Debounced end of continuous pan — only runs after movement stops (not on every `ended` flicker).
    private func scheduleGestureScrollFinish() {
        gestureScrollIdleWorkItem?.cancel()
        gestureInertiaWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.gestureDidContinuousScroll else { return }
            self.finishContinuousColumnScroll()
        }
        gestureScrollIdleWorkItem = work
        // Shorter idle → inertia starts sooner (feels snappier than 550ms).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private var isColumnPanActive: Bool {
        isGestureScrolling || gestureDidContinuousScroll
    }

    /// Settings, plugin panels, palette, quake/notepad — do not steal focus to tiled windows.
    private func chromeBlocksFocusFollowsMouse() -> Bool {
        AlwmChromeFocus.blocksFocusFollowsMouse(
            overlaysCaptureFocus: overlaysCaptureFocus,
            paletteVisible: palette.isVisible,
            overviewVisible: overview.isVisible,
            settingsVisible: settingsUI.isVisible
        )
    }

    private func scheduleFocusWindowUnderMouse() {
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
            self.ffmLastRun = Date()
            self.focusWindowUnderMouse()
        }
        ffmWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Frontmost on-screen CG window owner under an AX-space point (top-left origin).
    /// Used so emoji/sticker popups that spill past a tile don't lose FFM to the neighbor.
    private func cgOwnerPIDUnderPoint(axX: Double, axY: Double) -> pid_t? {
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

    private func focusWindowUnderMouse() {
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

    private func startIPC() throws {
        try ipc.start()
        ipc.handler = { [weak self] request in
            guard let self else {
                return IPCResponse(id: request.id, ok: false, message: "manager gone")
            }
            let semaphore = DispatchSemaphore(value: 0)
            var response = IPCResponse(id: request.id, ok: false, message: "pending")
            DispatchQueue.main.async {
                response = self.handleIPC(request)
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 2)
            return response
        }
    }

    private func handleIPC(_ request: IPCRequest) -> IPCResponse {
        let cmd = ([request.command] + request.args).joined(separator: " ")
        let parts = cmd.split(separator: " ").map(String.init)
        guard let head = parts.first else {
            return IPCResponse(id: request.id, ok: false, message: "empty command")
        }
        switch head {
        case "focus":
            if let dir = parts.dropFirst().first, let d = Direction(rawValue: dir) {
                handleAction("focus.\(d.rawValue)")
                return IPCResponse(id: request.id, ok: true, message: "focused \(dir)")
            }
        case "move":
            if let dir = parts.dropFirst().first, let d = Direction(rawValue: dir) {
                handleAction("move.\(d.rawValue)")
                return IPCResponse(id: request.id, ok: true, message: "moved \(dir)")
            }
        case "switch-workspace", "workspace":
            if let id = parts.dropFirst().first {
                handleAction("workspace.\(id)")
                return IPCResponse(id: request.id, ok: true, message: "workspace \(id)")
            }
        case "move-to-workspace", "send":
            if let id = parts.dropFirst().first {
                handleAction("move.to.workspace.\(id)")
                return IPCResponse(id: request.id, ok: true, message: "moved to \(id)")
            }
        case "resize":
            if let dir = parts.dropFirst().first {
                handleAction("resize.\(dir)")
                return IPCResponse(id: request.id, ok: true, message: "resize \(dir)")
            }
        case "overview":
            return IPCResponse(id: request.id, ok: false, message: "overview removido")
        case "quake":
            handleAction("quake.toggle")
            return IPCResponse(id: request.id, ok: true, message: "quake toggled")
        case "notepad":
            handleAction("notepad.toggle")
            return IPCResponse(id: request.id, ok: true, message: "notepad toggled")
        case "palette":
            handleAction("palette.toggle")
            return IPCResponse(id: request.id, ok: true, message: "palette toggled")
        case "float":
            let mode = parts.dropFirst().first ?? "toggle"
            handleAction("float.\(mode)")
            return IPCResponse(id: request.id, ok: true, message: "float \(mode)")
        case "settings":
            handleAction("settings.open")
            return IPCResponse(id: request.id, ok: true, message: "settings")
        case "dump":
            handleAction("debug.dump")
            return IPCResponse(id: request.id, ok: true, message: "dumped")
        case "relayout":
            handleAction("relayout")
            return IPCResponse(id: request.id, ok: true, message: "relayout")
        case "status":
            let active = workspaces.activeWorkspaceByMonitor[primaryMonitorID] ?? "?"
            return IPCResponse(
                id: request.id,
                ok: true,
                message: "ok",
                data: [
                    "workspace": active,
                    "windows": String(windowsByID.count),
                    "tiled": String(windowsByID.values.filter(\.isTiled).count),
                    "monitors": String(monitors.monitors.count),
                    "quake": quake.isVisible ? "visible" : "hidden",
                    "quakeDebug": quake.debugDescription,
                    "axTrusted": AXTracker.isTrusted ? "yes" : "no",
                    "axTracked": String(ax.lastScanAcceptedCount),
                    "axRaw": String(ax.lastScanRawWindowCount),
                    "inputMonitoring": Permissions.inputMonitoringGranted() ? "yes" : "no",
                    "screenRecording": Permissions.screenRecordingGranted() ? "yes" : "no"
                ]
            )
        case "rescan":
            ax.scanAll()
            ingest(windows: ax.currentWindows)
            applyWorkspaceVisibility(animated: false)
            refreshChrome()
            return IPCResponse(
                id: request.id,
                ok: true,
                message: "rescanned",
                data: [
                    "windows": String(windowsByID.count),
                    "axTrusted": AXTracker.isTrusted ? "yes" : "no"
                ]
            )
        default:
            handleAction(cmd)
            return IPCResponse(id: request.id, ok: true, message: "ran \(cmd)")
        }
        return IPCResponse(id: request.id, ok: false, message: "bad args")
    }

    public func handleAction(_ action: String) {
        let isFocusAction = action.hasPrefix("focus.")
        let isTileGeometryAction = [
            "move.left", "move.right", "move.up", "move.down",
            "resize.left", "resize.right", "resize.up", "resize.down",
            "column.maximize", "maximize.column",
            "scroll.columns", "scroll.left", "scroll.right"
        ].contains(action)
        let monitor: MonitorInfo? = isTileGeometryAction
            ? (monitorForTileAction() ?? monitorForAction())
            : monitorForAction()
        guard let monitor else { return }
        let usable = engine.usableArea(monitor: monitor.layoutFrame)
        let mainHeight = Double(NSScreen.screens.first?.frame.height ?? CGFloat(monitor.frame.height))

        // Move/resize/maximize need a tiled AX target — never a float (that used to
        // mutate the previous tile). Orphans get reinserted before geometry mutates.
        if isTileGeometryAction {
            guard let target = actionTargetTileWindow(on: monitor),
                  windowsByID[target]?.isTiled == true
            else { return }
            if action.hasPrefix("move."),
               let home = workspaces.activeWorkspaceByMonitor[monitor.id] {
                if let last = lastTileMoveDedupe,
                   last.0 == action, last.1 == home,
                   Date().timeIntervalSince(last.2) < 0.35 {
                    return
                }
                lastTileMoveDedupe = (action, home, Date())
            }
            if workspaces.workspaceID(containing: target) == nil {
                reinsertOrphanTiles()
                guard workspaces.workspaceID(containing: target) != nil else { return }
            }
            syncColumnFocus(to: target)
        } else if isFocusAction {
            // Start from the AX-focused tile so the first arrow is relative to what you see.
            if let target = actionTargetWindowID(),
               windowsByID[target]?.isTiled == true {
                syncColumnFocus(to: target)
            }
        }

        switch action {
        case "focus.left":
            mutateWorkspaceForAction(on: monitor) {
                engine.focus(.left, workspace: &$0, usable: usable, windows: windowsByID, monitor: monitor.layoutFrame)
            }
        case "focus.right":
            mutateWorkspaceForAction(on: monitor) {
                engine.focus(.right, workspace: &$0, usable: usable, windows: windowsByID, monitor: monitor.layoutFrame)
            }
        case "focus.up":
            mutateWorkspaceForAction(on: monitor) {
                engine.focus(.up, workspace: &$0, usable: usable, windows: windowsByID, monitor: monitor.layoutFrame)
            }
        case "focus.down":
            mutateWorkspaceForAction(on: monitor) {
                engine.focus(.down, workspace: &$0, usable: usable, windows: windowsByID, monitor: monitor.layoutFrame)
            }
        case "move.left":
            suppressIngestReassignUntil = Date().addingTimeInterval(0.45)
            mutateWorkspaceForAction(on: monitor, scopeToActiveWorkspace: true) { engine.moveFocused(.left, workspace: &$0, usable: usable) }
        case "move.right":
            suppressIngestReassignUntil = Date().addingTimeInterval(0.45)
            mutateWorkspaceForAction(on: monitor, scopeToActiveWorkspace: true) { engine.moveFocused(.right, workspace: &$0, usable: usable) }
        case "move.up":
            suppressIngestReassignUntil = Date().addingTimeInterval(0.45)
            mutateWorkspaceForAction(on: monitor, scopeToActiveWorkspace: true) { engine.moveFocused(.up, workspace: &$0, usable: usable) }
        case "move.down":
            suppressIngestReassignUntil = Date().addingTimeInterval(0.45)
            mutateWorkspaceForAction(on: monitor, scopeToActiveWorkspace: true) { engine.moveFocused(.down, workspace: &$0, usable: usable) }
        case "scroll.columns":
            mutateWorkspaceForAction(on: monitor) {
                let maxO = engine.maxViewOffset(workspace: $0, usable: usable)
                engine.scroll(by: usable.width * 0.4, workspace: &$0, maxOffset: maxO)
            }
        case "scroll.left":
            mutateWorkspaceForAction(on: monitor) {
                let maxO = engine.maxViewOffset(workspace: $0, usable: usable)
                engine.scroll(by: -usable.width * 0.4, workspace: &$0, maxOffset: maxO)
            }
        case "scroll.right":
            mutateWorkspaceForAction(on: monitor) {
                let maxO = engine.maxViewOffset(workspace: $0, usable: usable)
                engine.scroll(by: usable.width * 0.4, workspace: &$0, maxOffset: maxO)
            }
        case "workspace.prev":
            cycleWorkspace(by: -1, on: monitorForWorkspaceCycle().id)
            return
        case "workspace.next":
            cycleWorkspace(by: 1, on: monitorForWorkspaceCycle().id)
            return
        case "resize.left":
            mutateWorkspaceForAction(on: monitor) { engine.resizeFocused(by: -80, workspace: &$0, usable: usable) }
        case "resize.right":
            mutateWorkspaceForAction(on: monitor) { engine.resizeFocused(by: 80, workspace: &$0, usable: usable) }
        case "resize.up":
            guard let target = actionTargetWindowID() else { return }
            syncColumnFocus(to: target)
            mutateWorkspaceForAction(on: monitor) {
                engine.resizeFocusedHeight(
                    by: -80,
                    workspace: &$0,
                    usable: usable,
                    stackExcluded: [],
                    for: target
                )
            }
        case "resize.down":
            guard let target = actionTargetWindowID() else { return }
            syncColumnFocus(to: target)
            mutateWorkspaceForAction(on: monitor) {
                engine.resizeFocusedHeight(
                    by: 80,
                    workspace: &$0,
                    usable: usable,
                    stackExcluded: [],
                    for: target
                )
            }
        case "overview.toggle":
            return
        case "palette.toggle":
            palette.toggle(
                monitor: monitor,
                mainHeight: mainHeight,
                bindings: configStore.config.hotkeys
            )
            return
        case "quake.toggle":
            toggleQuake(monitor: monitor)
            return
        case "notepad.toggle":
            toggleNotepad(monitor: monitor)
            return
        case "notepad.new":
            openNewNotepad(monitor: monitor)
            return
        case "capture.region":
            capture.captureRegion()
            return
        case "capture.display":
            capture.captureDisplay()
            return
        case "capture.record.toggle":
            capture.toggleRecording()
            return
        case "float.toggle":
            toggleFloatFocused()
        case "float.on":
            setFloatFocused(true)
        case "float.off":
            setFloatFocused(false)
        case "column.maximize", "maximize.column":
            mutateWorkspaceForAction(on: monitor) {
                engine.toggleMaximizeFocusedColumn(workspace: &$0, usable: usable)
            }
        case "settings.open":
            settingsUI.open(config: configStore.config)
            return
        case "settings.open.plugins":
            settingsUI.open(config: configStore.config, initialPane: SettingsPane.plugins.rawValue)
            return
        case "debug.dump":
            dumpRuntimeState()
            return
        case "relayout":
            relayout(animated: true)
            refreshChrome()
            return
        default:
            if action.hasPrefix("notepad.open.") {
                let raw = String(action.dropFirst("notepad.open.".count))
                if let id = UUID(uuidString: raw) {
                    openNotepad(pageID: id)
                }
                return
            }
            if action.hasPrefix("move.to.workspace.") {
                let id = String(action.dropFirst("move.to.workspace.".count))
                moveFocusedToWorkspace(id, follow: false)
                return
            }
            if action.hasPrefix("send.workspace.") {
                let id = String(action.dropFirst("send.workspace.".count))
                moveFocusedToWorkspace(id, follow: false)
                return
            }
            if action.hasPrefix("workspace.") {
                let id = String(action.dropFirst("workspace.".count))
                switchWorkspace(id: id, on: monitor.id)
                return
            } else {
                return
            }
        }

        let stackResizeTarget: WindowID? = {
            if action.hasPrefix("move.") || action == "resize.up" || action == "resize.down" {
                return actionTargetTileWindow(on: monitor)
            }
            return nil
        }()

        // After focus/move, raise the workspace's focused tile — not the stale AX id
        // (re-focusing actionTarget undid focus.* navigation).
        let focusID: WindowID? = {
            if let home = actionWorkspaceID(for: monitor) {
                return workspaces.workspaces[home]?.focusedWindowID
            }
            return workspaces.activeWorkspace(for: monitor.id)?.focusedWindowID
                ?? actionTargetWindowID()
        }()
        // Resize + move: sync apply — animated lerp fights AX enforce / Quake visibility and
        // leaves tiles mid-frame (especially after scratchpad adopt).
        let syncLayout = action.hasPrefix("resize.") || action.hasPrefix("move.")
            || action == "column.maximize" || action == "maximize.column"
        if action.hasPrefix("move.") {
            let home = workspaces.activeWorkspaceByMonitor[monitor.id]
                ?? actionTargetTileWindow(on: monitor).flatMap { authoritativeHome(for: $0) }
            if let home {
                persistRuntimeState(forceWorkspaceLayouts: [home])
            }
        }
        if action.hasPrefix("move."), let home = workspaces.activeWorkspaceByMonitor[monitor.id]
            ?? actionTargetTileWindow(on: monitor).flatMap({ authoritativeHome(for: $0) }) {
            let layoutMon = displayMonitor(forHome: home, fallback: monitor)
            suppressGeometryEnforce(for: 0.5)
            applyWorkspaceTileLayout(
                home,
                on: layoutMon,
                forceReveal: true,
                movedID: actionTargetTileWindow(on: monitor)
            )
            applyAllActiveStackColumns()
            scheduleTileFrameEnforcement(stackAnchor: stackResizeTarget)
        } else if action.hasPrefix("resize.") || action.hasPrefix("move.") {
            relayoutWithFrameRetry(stackAnchor: stackResizeTarget, on: monitor)
        } else {
            relayout(animated: !syncLayout, on: monitor)
        }
        if let focusID {
            axFocusedWindowID = focusID
            if !overlaysCaptureFocus {
                ax.focus(focusID)
                maybeWarpCursor(to: focusID)
            }
        }
        refreshChrome()

        switch action {
        case "move.left", "move.right", "move.up", "move.down",
             "resize.left", "resize.right", "resize.up", "resize.down",
             "column.maximize", "maximize.column",
             "float.toggle", "float.on", "float.off":
            if action.hasPrefix("move."),
               let home = workspaces.activeWorkspaceByMonitor[monitor.id],
               let ws = workspaces.workspaces[home] {
                let target = actionTargetTileWindow(on: monitor)?.token ?? "?"
                let widths = ws.columns.map { Int($0.width) }.map(String.init).joined(separator: "+")
                logMove("tile \(action) ws=\(home) win=\(target) cols=\(ws.columns.count) widths=\(widths)")
            }
            if let home = workspaces.activeWorkspaceByMonitor[monitor.id] ?? actionWorkspaceID(for: monitor) {
                persistRuntimeState(forceWorkspaceLayouts: [home])
            } else {
                persistRuntimeState()
            }
        default:
            break
        }
    }

    private func toggleQuake(monitor: MonitorInfo) {
        let settings = configStore.config.settings.quake
        let monitorsFrames = monitors.monitors.map(\.frame)
        quake.toggle(
            settings: settings,
            monitor: monitor,
            windows: windowsByID,
            ax: ax,
            applyFrame: { @Sendable [weak self] id, frame in
                Task { @MainActor in
                    guard let self else { return }
                    if self.quake.isVisible {
                        self.ax.setMinimized(false, id: id)
                        self.ax.apply(frame: frame, to: id)
                    } else {
                        self.ax.parkAndHide(frame: frame, id: id, monitors: monitorsFrames)
                    }
                    self.lastFrames[id] = frame
                }
            },
            focusTiled: { @Sendable [weak self] in
                Task { @MainActor in
                    guard let self, !self.overlaysCaptureFocus else { return }
                    guard let mon = self.primaryMonitor() else { return }
                    if let focused = self.workspaces.activeWorkspace(for: mon.id)?.focusedWindowID {
                        self.ax.focus(focused)
                    }
                }
            }
        )
        if let id = quake.windowID {
            workspaces.removeWindowEverywhere(id)
            floatingOverrides.insert(id)
            quake.markScratchpad(in: &windowsByID)
            // Always suppress dismiss around toggle — show animation focuses late,
            // and AX focus noise must not slide the panel away immediately.
            suppressQuakeDismissUntil = Date().addingTimeInterval(0.8)
            if quake.isVisible {
                let frame = quake.visibleFrame(settings: settings, monitor: monitor)
                ax.setMinimized(false, id: id)
                ax.apply(frame: frame, to: id)
                ax.focus(id)
                lastFrames[id] = frame
                preferredOverlayFocus = .quake
                suppressGeometryEnforce(for: 1.0)
            } else {
                let hidden = quake.hiddenFrame(settings: settings, monitor: monitor)
                ax.parkAndHide(frame: hidden, id: id, monitors: monitorsFrames)
                lastFrames[id] = hidden
                applyFluidLayout(animated: false, onlyMonitor: monitor)
            }
        } else {
            suppressQuakeDismissUntil = Date().addingTimeInterval(2.0)
        }
        updateOverlayInputMode()
        refreshChrome()
    }

    private func toggleFloatFocused() {
        guard let id = actionTargetWindowID() else { return }
        toggleFloat(id)
    }

    private func toggleFloat(_ id: WindowID) {
        setFloat(id, floating: !(windowsByID[id]?.isFloating ?? false))
    }

    private func setFloatFocused(_ floating: Bool) {
        guard let id = actionTargetWindowID() else { return }
        setFloat(id, floating: floating)
    }

    private func setFloat(_ id: WindowID, floating: Bool) {
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

    private func closeWindow(_ id: WindowID) {
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
        persistRuntimeState()
        relayout(animated: false, on: layoutScopeMonitor(for: id))
        refreshChrome()
        if wasLayoutTile {
            scheduleQuitIfLastLayoutWindowClosed(pid: pid, bundleID: bundleID, homeWasActive: true)
        }
    }

    /// macOS often keeps WhatsApp/Calendar/Discord running after the red X.
    /// If that was the last *live* layout window of the app, quit the process.
    private func scheduleQuitIfLastLayoutWindowClosed(pid: pid_t, bundleID: String?, homeWasActive: Bool) {
        guard homeWasActive else { return }
        guard !isBootstrapping, !isResumeRecovering else { return }
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        let bid = (bundleID ?? "").lowercased()
        if bid.hasPrefix("dev.alwm") || bid.contains(".alwm") { return }
        if bid == "com.apple.finder" { return }
        if bid.hasPrefix("com.apple.dock") || bid.hasPrefix("com.apple.systemuiserver") { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.ax.scanAll()
            // Soft-missing ghosts stay in windowsByID briefly — only live AX windows count.
            let liveSamePid = self.ax.currentWindows.contains {
                $0.id.pid == pid && !$0.isIgnored && !$0.isScratchpad
                    && ($0.frame.width > 40 && $0.frame.height > 40)
            }
            if liveSamePid { return }
            self.logMove("quit last-window pid=\(pid) bundle=\(bundleID ?? "?")")
            self.quitApp(pid: pid)
        }
    }

    private func quitApp(pid: pid_t) {
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
        persistRuntimeState()
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

    private func cycleWorkspace(by delta: Int, on monitorID: CGDirectDisplayID) {
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

    private func switchWorkspace(id: String, on monitorID: CGDirectDisplayID, restoreLayout: Bool = false) {
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

        // Prevent AX focus / ingest from bouncing or reassigning during the switch.
        suppressWorkspaceFollowUntil = Date().addingTimeInterval(2.5)
        suppressIngestReassignUntil = Date().addingTimeInterval(2.5)
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

        if let mon = monitors.monitors.first(where: { $0.id == targetMonitorID }) {
            // Force column frames now — visibility alone can skip via isSettled / stale signature.
            applyWorkspaceTileLayout(id, on: mon, forceReveal: true, skipHeal: true)
            scheduleTileFrameEnforcement()

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
        // After focus, tuck leaky parked windows and re-assert tiles — Safari/Electron often
        // ignore the first reveal until a later pass (mouse hover used to be that pass).
        let monitorsSnapshot = monitors.monitors.map(\.frame)
        let destinationID = id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self, self.workspaceSwitchGeneration == switchGeneration else { return }
            let activeLater = Set(self.workspaces.activeWorkspaceByMonitor.values)
            self.settleParkedWindows(activeIDs: activeLater, monitors: monitorsSnapshot)
            if activeLater.contains(destinationID),
               let mon = self.monitors.monitors.first(where: {
                   self.workspaces.activeWorkspaceByMonitor[$0.id] == destinationID
               }) {
                self.visibilityForceReveal = true
                self.applyWorkspaceTileLayout(destinationID, on: mon, forceReveal: true, skipHeal: true)
                self.scheduleTileFrameEnforcement()
            }
            self.refreshBorder()
            self.refreshChrome()
        }
        // Second retry — same-PID Safari deminiaturize can land after the first pass.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard let self, self.workspaceSwitchGeneration == switchGeneration else { return }
            guard self.workspaces.activeWorkspaceByMonitor.values.contains(destinationID) else { return }
            if let mon = self.monitors.monitors.first(where: {
                self.workspaces.activeWorkspaceByMonitor[$0.id] == destinationID
            }) {
                self.visibilityForceReveal = true
                self.applyWorkspaceTileLayout(destinationID, on: mon, forceReveal: true, skipHeal: true)
                self.scheduleTileFrameEnforcement()
            }
            self.refreshChrome()
        }
        refreshChrome()
    }

    /// Bar icon click: go to that workspace and focus the window without reshuffling tiles.
    private func focusWorkspaceWindow(_ windowID: WindowID, workspaceID: String, on monitorID: CGDirectDisplayID) {
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

    /// Soft post-switch pass: hide stragglers without touching already-correct visible windows.
    private func settleParkedWindows(activeIDs: Set<String>, monitors: [Rect]) {
        guard !isApplyingVisibility else { return }
        ax.withMutation {
            for (id, win) in windowsByID where !win.isIgnored {
                if id == quake.windowID { continue }
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

    private func moveFocusedToWorkspace(_ workspaceID: String, follow: Bool = false) {
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

    /// Re-apply every tile in one workspace after a structural change (move/send window).
    private func applyWorkspaceTileLayout(
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

    /// Force-apply the engine tile frame (Electron/Telegram often ignore the first visibility pass).
    private func applyForcedTileFrame(for id: WindowID) {
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

    /// Ingest must not strip column slots during an explicit send-to-workspace.
    private func isMoveProtectedTile(_ id: WindowID) -> Bool {
        if let until = forcedTiledUntil[id], Date() < until { return true }
        if Date() < suppressIngestReassignUntil, windowWorkspace[id] != nil { return true }
        return false
    }

    private func isFloatRevealProtected(_ id: WindowID) -> Bool {
        guard let win = windowsByID[id], !win.isIgnored else { return false }
        let isFloat = win.isFloating || win.isScratchpad || floatingOverrides.contains(id)
        guard isFloat else { return false }
        guard let home = authoritativeHome(for: id), isHomeActiveOnAnyMonitor(home) else { return false }
        if let until = forcedFloatVisibleUntil[id], Date() < until { return true }
        if Date().timeIntervalSince(windowFirstTrackedAt[id] ?? .distantPast) < floatRevealGrace { return true }
        if axFocusedWindowID == id || ax.frontmostFocusedWindowID() == id { return true }
        return false
    }

    /// Focused or newly-opened tiled windows on an active workspace must not be
    /// parked/minimized by visibility sweeps (pre-layout frames look like monitor leaks).
    private func isTileRevealProtected(_ id: WindowID) -> Bool {
        guard let win = windowsByID[id], win.isTiled, !win.isIgnored else { return false }
        guard !win.isFloating, !win.isScratchpad, !floatingOverrides.contains(id) else { return false }
        guard let home = authoritativeHome(for: id), isHomeActiveOnAnyMonitor(home) else { return false }
        if axFocusedWindowID == id || ax.frontmostFocusedWindowID() == id { return true }
        return Date().timeIntervalSince(windowFirstTrackedAt[id] ?? .distantPast) < newWindowColumnGrace
    }

    private func isVisibilityRevealProtected(_ id: WindowID) -> Bool {
        isFloatRevealProtected(id) || isTileRevealProtected(id)
    }

    private func markFloatRevealProtected(_ id: WindowID, seconds: TimeInterval? = nil) {
        guard windowsByID[id] != nil else { return }
        let duration = seconds ?? floatRevealGrace
        forcedFloatVisibleUntil[id] = Date().addingTimeInterval(duration)
        if windowFirstTrackedAt[id] == nil {
            windowFirstTrackedAt[id] = Date()
        }
    }

    /// Reveal newly tracked floats on the active home without a full visibility pass (avoids tile storms).
    private func revealActiveFloats(ids: Set<WindowID>) {
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

    private func logMove(_ message: String) {
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

    /// Bar / saved tokens often lag AX window numbers (Telegram, Electron) — map to the live window.
    private func windowRef(for id: WindowID) -> RuntimeStateStore.WindowRef {
        if let win = windowsByID[id] { return RuntimeStateStore.WindowRef(window: win) }
        for layout in runtimeState.snapshot.workspaceLayouts.values {
            for ref in layout.columns.flatMap(\.windows) + layout.floating where ref.token == id.token {
                return ref
            }
        }
        return RuntimeStateStore.WindowRef(token: id.token)
    }

    private func resolveLiveWindowID(for id: WindowID, preferredWS: String?) -> WindowID? {
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

    /// Explicit move — pin this live window to the destination.
    /// Multi-window apps (several Safari/Cursor windows) must keep independent homes —
    /// never rematch siblings just because the disk snapshot still says "1 instance".
    private func applyStickyHomeForMove(_ workspaceID: String, win: ManagedWindow, live: WindowID) {
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

    /// Drop ghost tokens for the same app instance after resolving AX churn.
    /// When `workspaceScope` is set, never touch windows assigned to another workspace
    /// (e.g. Safari on WS1 + Safari on WS5 share a PID).
    /// Never remove other *live* windows — multi-window apps share pid+bundle legitimately.
    private func purgeStaleBundleTokens(
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

    private func bundleInstanceScore(_ id: WindowID) -> Int {
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

    private func workspaceHome(for id: WindowID) -> String? {
        if let sticky = windowWorkspace[id], workspaces.workspaces[sticky] != nil { return sticky }
        if let saved = runtimeState.assignment(for: id), workspaces.workspaces[saved] != nil { return saved }
        return workspaces.workspaceID(containing: id)
    }

    private func preferredBundleInstanceToken(among ids: [WindowID], bundleID: String) -> WindowID? {
        guard !ids.isEmpty else { return nil }
        if ids.count == 1 { return ids[0] }
        return ids.max(by: { bundleInstanceScore($0) < bundleInstanceScore($1) })
    }

    /// True when this window still has a live AX presence (not a churn ghost).
    private func isLiveBundleSibling(_ id: WindowID, liveAX: Set<WindowID>) -> Bool {
        liveAX.contains(id)
            && windowsByID[id] != nil
            && ax.currentFrame(of: id) != nil
            && !ax.isMinimized(id)
            && missingScanCounts[id] == nil
    }

    /// When AX churn replaces window numbers, drop *ghost* siblings before placement.
    /// Never eject other live windows of the same app (Cursor/Safari often have many).
    private func ejectStaleBundleInstance(from workspaceID: String, keeping id: WindowID) {
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

    /// AX token churn (Electron/WhatsApp) can leave duplicate pid+bundle entries in columns.
    /// Scoped per workspace — never merge Safari WS1 with Safari WS5 (same PID).
    /// Only drop ghosts; multiple live windows of the same app in one workspace are valid.
    private func dedupeBundleInstanceTokens() -> Set<String> {
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

    /// Remove ghost tiles that share pid+bundle with a live sibling in the same column.
    /// Multiple *live* Cursor/Safari windows in one column must never be collapsed.
    private func dedupeBundleTilesInColumns() -> Set<String> {
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

    /// Same app instance split across columns (token churn) — collapse when only one is truly live.
    private func collapseDuplicateBundleColumns() -> Set<String> {
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

    private func healBundleTokenChurn() -> Set<String> {
        var changed = dedupeBundleInstanceTokens()
        changed.formUnion(dedupeBundleTilesInColumns())
        changed.formUnion(collapseDuplicateBundleColumns())
        return changed
    }

    /// Disk snapshot can keep stale tokens after cross-workspace send — clear the source slot.
    private func removePersistedWindowRefs(_ ref: RuntimeStateStore.WindowRef, fromWorkspace wsID: String) {
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

    private func moveWindow(requestedID: WindowID, to workspaceID: String, follow: Bool = false) {
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
        persistRuntimeState(forceWorkspaceLayouts: forcePersist)
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

    /// Retry AX scan after launch if Accessibility was late or windows did not match the saved layout.
    private func scheduleAccessibilityRecoveryScans() {
        runLayoutRecoveryIfNeeded(force: false, delay: 0.8)
        runLayoutRecoveryIfNeeded(force: false, delay: 2.5)
    }

    private func savedTiledWindowCount() -> Int {
        runtimeState.snapshot.workspaceLayouts.values.reduce(0) { partial, layout in
            partial + layout.columns.reduce(0) { $0 + $1.windows.count }
        }
    }

    private func liveTiledWindowCount() -> Int {
        workspaces.workspaces.values.reduce(0) { partial, ws in
            partial + ws.columns.reduce(0) { $0 + $1.windows.count }
        }
    }

    private func needsLayoutRecovery(force: Bool) -> Bool {
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

    private func runLayoutRecoveryIfNeeded(force: Bool, delay: TimeInterval) {
        guard force || layoutRecoveryAttempts < maxLayoutRecoveryAttempts else { return }
        layoutRecoveryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.runLayoutRecovery(force: force)
        }
        layoutRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runLayoutRecovery(force: Bool) {
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
        let recovered = layoutLooksRecovered() && framesLookRestoredOnActiveWorkspaces()
        if recovered || layoutRecoveryAttempts >= maxLayoutRecoveryAttempts {
            layoutRecoveryAttempts = maxLayoutRecoveryAttempts
            resumeRecoveryEligibleUntil = Date.distantPast
            isResumeRecovering = false
            if recovered {
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

    private func isInPostLaunchLayoutGrace() -> Bool {
        Date() < postLaunchLayoutGraceUntil
    }

    private func primaryMonitor() -> MonitorInfo? {
        monitors.monitors.first(where: { $0.id == primaryMonitorID }) ?? monitors.monitors.first
    }

    /// Prefer the monitor under the mouse for workspace next/prev so the bar you look at
    /// is the one that cycles (focused-window monitor caused "cursor moved, still on WS1").
    private func monitorForWorkspaceCycle() -> MonitorInfo {
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

    /// Window that keyboard tiling actions should affect.
    /// Always prefer real AX / frontmost focus over the primary monitor's column focus.
    private func actionTargetWindowID() -> WindowID? {
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

    /// Monitor for ⌥⇧ move/resize — the display showing the active workspace under the cursor,
    /// never primaryMonitor() or AX frame (which jumps to the display below after a bad frame).
    private func monitorForTileAction() -> MonitorInfo? {
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

    /// Tile move/resize/focus must stay on the monitor's active workspace — never Safari on WS5
    /// while organizing WS1 (same PID / AX frontmost jumps processes).
    private func actionTargetTileWindow(on monitor: MonitorInfo) -> WindowID? {
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

    /// Point column focus at `id` so move/resize operate on the AX-focused window.
    private func syncColumnFocus(to id: WindowID) {
        guard let home = authoritativeHome(for: id) ?? workspaces.workspaceID(containing: id),
              var ws = workspaces.workspaces[home],
              let loc = engine.locate(id, in: ws)
        else { return }
        ws.focusedColumn = loc.col
        ws.focusedWindowInColumn[loc.col] = loc.row
        workspaces.setWorkspace(ws)
    }

    /// Home workspace for the current action target (tile or sticky float).
    private func actionWorkspaceID(for monitor: MonitorInfo) -> String? {
        if let id = actionTargetWindowID() {
            if let home = authoritativeHome(for: id) ?? workspaces.workspaceID(containing: id) {
                return home
            }
        }
        return workspaces.activeWorkspaceByMonitor[monitor.id]
    }

    /// Mutate the workspace that owns the action target (not blindly the active WS on a monitor).
    private func mutateWorkspaceForAction(
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

    /// Prefer the monitor that currently shows the focused window's workspace.
    private func monitorForAction() -> MonitorInfo? {
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

    /// Monitor to scope routine relayout/visibility — avoids cross-display flicker.
    private func layoutScopeMonitor(for windowID: WindowID? = nil) -> MonitorInfo? {
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

    private func focusedWindowID() -> WindowID? {
        guard let mon = primaryMonitor() else { return nil }
        return workspaces.activeWorkspace(for: mon.id)?.focusedWindowID
    }

    private func maybeWarpCursor(to id: WindowID) {
        guard !overlaysCaptureFocus else { return }
        guard configStore.config.settings.moveMouseToFocusedWindow, !focusSourceIsMouse else { return }
        guard let frame = lastFrames[id] else { return }
        let mainH = Double(NSScreen.screens.first?.frame.height ?? 900)
        let cocoaY = mainH - frame.midY
        warpCursor(to: CGPoint(x: frame.midX, y: cocoaY))
    }

    private func warpCursor(to point: CGPoint) {
        let event = CGEvent(source: nil)
        event?.type = .mouseMoved
        CGWarpMouseCursorPosition(point)
    }

    private func mutateActive(_ monitorID: CGDirectDisplayID, _ body: (inout WorkspaceState) -> Void) {
        workspaces.updateActiveWorkspace(for: monitorID, body)
    }

    private func focusWindow(_ id: WindowID, raise: Bool = true) {
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

    /// Apply the expected tile (or last good) frame before AX raise/deminiaturize.
    private func revealBeforeFocus(_ id: WindowID) {
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

    /// If raise still left an edge clamp / dock thumb, force one more reveal + relayout.
    private func healUnusableFocusedFrame(_ id: WindowID) {
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

    /// Engine target for a tiled window on its home workspace.
    private func expectedTileFrame(for id: WindowID) -> Rect? {
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

    /// Focus a floating / unassigned window that belongs to the active workspace on `monitorID`.
    private func focusFloatingWindow(on monitorID: CGDirectDisplayID) {
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

    /// Drop tracked windows that AX no longer reports (fixes soft-delete ghosts in ⌀).
    private func pruneDeadTrackedWindows() {
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
            self.axFocusedWindowID = id
            guard let id else {
                self.refreshChrome()
                return
            }

            // Quake / notepad / settings / plugin panels — relayout and AX noise must not
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

    /// Red-X / AX destroy — drop tile immediately (no soft-delete lag → no ghost column/icon).
    public nonisolated func axTrackerWindowDidClose(_ id: WindowID) {
        Task { @MainActor in
            self.handleUserClosedWindow(id)
        }
    }

    private func handleUserClosedWindow(_ id: WindowID) {
        if id == quake.windowID || isQuakeOwned(id) {
            handleQuakeWindowClosed()
            persistRuntimeState()
            refreshChrome()
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

    /// If a tiled window on an active workspace drifted from the engine target, re-apply layout.
    private func scheduleGeometryEnforce(for id: WindowID) {
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
                if let expected, let live = self.ax.currentFrame(of: id),
                   abs(live.x - expected.x) < 10,
                   abs(live.width - expected.width) < 12,
                   abs(live.y - expected.y) < 48,
                   live.maxY <= expected.maxY + 80 {
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

    private func scheduleGeometryEnforceDebounced(after delay: TimeInterval = 0.22) {
        geometryEnforceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let any = self.geometryEnforcePending.first else { return }
            self.scheduleGeometryEnforce(for: any)
        }
        geometryEnforceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func ingest(windows: [ManagedWindow]) {
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
            if isQuakeOwned(w.id) || quake.windowID == w.id || pendingCandidate {
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
                handleQuakeWindowClosed()
                forgotten.insert(id)
                missingScanCounts.removeValue(forKey: id)
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
            quake.forgetIfFullyGone(windows: merged)
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
        // Pending launch: keep candidates out of columns even before windowID binds.
        let quakeStripped = stripPendingQuakeFromColumns()

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
                    // After update/relaunch, a mass "added" set is restore churn — don't flatten onto active WS.
                    if isInPostLaunchLayoutGrace(), addedTiles.count >= 2 {
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

    /// AX frame/title events during a workspace switch must not queue another hide/show pass.
    private func shouldDeferVisibilityRefreshFromIngest() -> Bool {
        Date() < suppressWorkspaceFollowUntil
            || Date() < suppressIngestReassignUntil
            || isApplyingVisibility
            || overlaysCaptureFocus
    }

    /// Same window set, only titles changed — skip persist/relayout storms.
    private func applyTitleOnlyIngest(from mapped: [WindowID: ManagedWindow]) -> Bool {
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

    private func scheduleScopedLayoutRefresh(animated: Bool, delay: TimeInterval, monitor: MonitorInfo?) {
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

    private func scheduleVisibilityRefresh(animated: Bool, delay: TimeInterval) {
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

    /// Electron apps often ignore the first AX resize after a height change.
    private func relayoutWithFrameRetry(stackAnchor: WindowID? = nil, on monitor: MonitorInfo? = nil) {
        suppressGeometryEnforce(for: 0.45)
        let scope = monitor ?? layoutScopeMonitor(for: stackAnchor)
        applyFluidLayout(animated: false, onlyMonitor: scope)
        if let stackAnchor {
            applyStackColumnFrames(for: stackAnchor)
        }
        scheduleTileFrameEnforcement(stackAnchor: stackAnchor)
    }

    /// Re-assert every multi-tile stack column on active workspaces (paired x/y/width/height).
    private func applyAllActiveStackColumns() {
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

    private func suppressGeometryEnforce(for seconds: Double) {
        suppressGeometryEnforceUntil = Date().addingTimeInterval(seconds)
    }

    /// Keep stack tiles inside the usable strip without expanding to full-screen.
    private func clampStackTileFrame(_ frame: Rect, usable: Rect) -> Rect {
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

    /// Fit stacked tiles into usable height while preserving relative heights (leafWeights).
    /// Equal-split used to fight Electron minSize and pump WhatsApp/Discord forever.
    private func tessellateColumnStack(
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

    /// Soft-missing / minimized tiles keep their column slot but must not steal stack height
    /// (Safari AX churn left the live window at half column until leave/re-enter healed).
    private func stackExcludedFromLayout() -> Set<WindowID> {
        Set(windowsByID.keys.filter { id in
            guard let win = windowsByID[id], win.isTiled else { return false }
            if cachedIsMinimized(id) { return true }
            if missingScanCounts[id] != nil { return true }
            return false
        })
    }

    /// Apply computed frames column-by-column (stack Y-order + reveal). Column membership wins over AX float.
    private func applyWorkspaceColumnTileFrames(
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
                        return live.maxY > usable.maxY + 24
                            || live.height > frame.height + 80
                            || live.width > frame.width + 40
                    }
                    if !overflow { break }
                    _ = attempt
                }
            }
        }
        tuckWindowsLeakingWrongMonitor(preferredMonitorFrame: monitor.layoutFrame, onlyOnMonitor: monitor)
        return applied
    }

    /// Re-apply every visible tile in the focused window's stack column (paired height resize).
    private func applyStackColumnFrames(for id: WindowID) {
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

    /// Tiled windows excluded from horizontal layout math.
    /// On the active workspace only wrong-home tiles are excluded — soft-missing /
    /// minimized siblings must keep their horizontal column slot on switch-back
    /// (otherwise Safari expands edge-to-edge and forgets WhatsApp/Discord ratios).
    /// Vertical space is still protected via `stackExcludedFromLayout`.
    private func layoutExcludedWindowIDs(for wsID: String, monitor: MonitorInfo? = nil) -> Set<WindowID> {
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

    private func cachedIsMinimized(_ id: WindowID) -> Bool {
        if let cached = minimizedCache[id] { return cached }
        let value = ax.isMinimized(id)
        minimizedCache[id] = value
        return value
    }

    private func beginLayoutPass() {
        layoutExcludedCache.removeAll(keepingCapacity: true)
        minimizedCache.removeAll(keepingCapacity: true)
        structuralHealDoneThisPass = false
    }

    /// One heal/reinsert per layout pass — ingest + visibility must not double-run.
    private func runStructuralHealIfNeeded(reinsert: Bool = true) {
        if structuralHealDoneThisPass { return }
        structuralHealDoneThisPass = true
        healStaleColumnEntries()
        if reinsert {
            reinsertOrphanTiles()
        }
    }

    private func syncTokenIndex() {
        tokenByWindowToken = Dictionary(uniqueKeysWithValues: windowsByID.keys.map { ($0.token, $0) })
    }

    /// AX token churn: rebind a soft-missing column slot to a newly seen live window.
    @discardableResult
    private func rebindAddedWindowIfTokenChurn(_ newID: WindowID) -> Bool {
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

    private func rebindWindowIdentity(from stale: WindowID, to live: WindowID, home: String) {
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

    private func visibilitySignature(
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

    /// Keep tiled windows inside the home monitor (stack Y must not drift to another display).
    private func clampHorizontalTileFrame(_ frame: Rect, for id: WindowID) -> Rect {
        guard let home = authoritativeHome(for: id) else { return frame }
        let mon = displayMonitor(
            forHome: home,
            fallback: primaryMonitor() ?? monitors.monitors[0]
        )
        let usable = engine.usableArea(monitor: mon.layoutFrame)
        return clampStackTileFrame(frame, usable: usable)
    }

    /// Re-apply computed tile frames on active workspaces (Electron often ignores the first AX resize).
    private func enforceActiveTileFrames() {
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
                    ax.reveal(frame: target, id: a.windowID)
                    if shouldForceTileExpand(wsID)
                        || !ax.isSettled(id: a.windowID, frame: target, monitors: monitorFrames) {
                        ax.applyFrameOnly(frame: target, to: a.windowID)
                    }
                    lastFrames[a.windowID] = ax.currentFrame(of: a.windowID) ?? target
                }
            }
        }
        tuckWindowsLeakingWrongMonitor()
    }

    private func scheduleTileFrameEnforcement(stackAnchor: WindowID? = nil) {
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

    /// Scroll / zero-width fill only — never prune columns on workspace show.
    private func prepareWorkspaceLayoutForDisplay(_ wsID: String, monitor: MonitorInfo) {
        guard var ws = workspaces.workspaces[wsID] else { return }
        let before = ws
        syncColumnWidthsToUsable(workspace: &ws, workspaceID: wsID)
        if ws != before {
            workspaces.setWorkspace(ws)
        }
    }

    /// Drop leading column slots that have no window ids (empty placeholders reserve width).
    private func stripLeadingVacantColumns(wsID: String, layoutExcluded: Set<WindowID>) {
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

    /// Remove column slots with no window ids (placeholders). Never drop columns that still
    /// own tiled windows — they may be layout-excluded until AX catches up after relaunch.
    private func pruneVacantColumnSlots(wsID: String) {
        guard var ws = workspaces.workspaces[wsID] else { return }
        let before = ws.columns.count
        ws.columns.removeAll { $0.windows.isEmpty }
        guard ws.columns.count != before else { return }
        ws.focusedColumn = min(max(0, ws.focusedColumn), max(0, ws.columns.count - 1))
        workspaces.setWorkspace(ws)
    }

    private func prepareAllActiveWorkspaceLayouts() {
        for mon in monitors.monitors {
            guard let wsID = workspaces.activeWorkspaceByMonitor[mon.id] else { continue }
            prepareWorkspaceLayoutForDisplay(wsID, monitor: mon)
        }
    }

    private func setupSystemResumeObservers() {
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
            Task { @MainActor [weak self] in
                self?.prepareForSystemSleep()
            }
        }
        systemObservers.append(willSleep)

        let screensSleep = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.prepareForSystemSleep()
            }
        }
        systemObservers.append(screensSleep)

        let wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
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
            Task { @MainActor [weak self] in
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
            Task { @MainActor [weak self] in
                guard let self, Date() < self.resumeRecoveryEligibleUntil else { return }
                self.scheduleSystemResumeRecovery(delay: 1.2)
            }
        }
        systemObservers.append(active)
    }

    /// Persist a known-good layout before the machine sleeps (AX is unreliable on wake).
    private func prepareForSystemSleep() {
        isResumeRecovering = false
        persistRuntimeState()
        preSleepLayoutFingerprint = layoutRecoveryFingerprint()
        if configStore.config.settings.developerMode {
            NSLog("ALWM: prepared for sleep — fingerprint=%@", preSleepLayoutFingerprint ?? "?")
        }
    }

    private func noteSystemWakeForResumeRecovery() {
        resumeRecoveryEligibleUntil = Date().addingTimeInterval(240)
        layoutRecoveryAttempts = 0
        isResumeRecovering = true
        lastVisibilitySignature = nil
        lastSnapSignature.removeAll()
        forceTileExpandUntil.removeAll()
    }

    /// AX often returns partial window lists for several seconds after sleep — retry recovery.
    private func scheduleStaggeredResumeRecovery() {
        for work in resumeRecoveryWorkItems { work.cancel() }
        resumeRecoveryWorkItems.removeAll()
        // Longer tail: Electron/Safari rematerialize window numbers slowly after wake.
        for delay in [0.8, 2.0, 5.0, 10.0, 18.0, 28.0] {
            let work = DispatchWorkItem { [weak self] in
                self?.recoverAfterSystemResume()
            }
            resumeRecoveryWorkItems.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func scheduleSystemResumeRecovery(delay: TimeInterval = 0.6) {
        resumeRecoveryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.recoverAfterSystemResume()
        }
        resumeRecoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// After sleep / relaunch: re-bind sticky homes and re-apply saved column layouts + frames.
    private func recoverAfterSystemResume() {
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

        let recovered = layoutLooksRecovered() && framesLookRestoredOnActiveWorkspaces()
        if recovered {
            isResumeRecovering = false
            resumeRecoveryEligibleUntil = Date.distantPast
            // Safe to refresh disk tokens (window numbers may have changed) now that layout matches.
            persistRuntimeState()
        } else {
            runLayoutRecoveryIfNeeded(force: true, delay: 2.5)
        }
        NSLog(
            "ALWM: resume recovery — windows=%d savedTiles=%d liveTiles=%d recovered=%@",
            windowsByID.count,
            savedTiledWindowCount(),
            liveTiledWindowCount(),
            recovered ? "yes" : "no"
        )
    }

    /// Re-apply engine frames for every workspace currently shown on a monitor.
    private func applyActiveWorkspaceTileLayoutsAfterResume() {
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

    /// Drop sticky map entries whose tokens are no longer live (common after sleep token churn).
    private func purgeStaleStickyTokens() {
        let live = Set(windowsByID.keys)
        let stale = windowWorkspace.keys.filter { !live.contains($0) }
        for id in stale {
            windowWorkspace.removeValue(forKey: id)
        }
        // Keep runtime assignments for live windows only; disk layout refs still restore via rematch.
        runtimeState.pruneWindows(keeping: live)
    }

    private func layoutRecoveryFingerprint() -> String {
        runtimeState.snapshot.workspaceLayouts.keys.sorted().map { wsID in
            guard let snap = runtimeState.snapshot.workspaceLayouts[wsID] else { return "\(wsID):" }
            let cols = snap.columns.map { col in
                col.windows.map { "\($0.bundleID ?? "?"):\($0.token)" }.joined(separator: ",")
                    + "@\(Int(col.width))"
            }.joined(separator: "|")
            return "\(wsID):\(cols)"
        }.joined(separator: ";")
    }

    /// Active tiles should sit on the monitor that currently shows their home workspace.
    private func framesLookRestoredOnActiveWorkspaces() -> Bool {
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

    /// True when saved layout is fully reflected in live columns (or nothing to restore).
    private func layoutLooksRecovered() -> Bool {
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

    /// Fast layout: only AX position/size. Minimize/park-hide is reserved for
    /// real workspace switches (`applyWorkspaceVisibility`).
    private func applyFluidLayout(animated: Bool, onlyMonitor: MonitorInfo? = nil) {
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
                        ax.parkOffscreen(frame: frame, id: id, monitors: allMonitorFrames)
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

    /// Sticky home: in-memory map, then disk, then column containment.
    private func authoritativeHome(for id: WindowID) -> String? {
        if let sticky = windowWorkspace[id] { return sticky }
        if let saved = runtimeState.assignment(for: id),
           workspaces.workspaces[saved] != nil {
            return saved
        }
        return workspaces.workspaceID(containing: id)
    }

    /// Monitor where `home` is the active workspace right now (layout target).
    private func displayMonitor(forHome home: String, fallback: MonitorInfo) -> MonitorInfo {
        monitors.monitors.first { workspaces.activeWorkspaceByMonitor[$0.id] == home }
            ?? workspaces.preferredMonitor(forWorkspace: home, monitors: monitors.monitors)
            ?? fallback
    }

    private func isHomeActiveOnAnyMonitor(_ home: String) -> Bool {
        workspaces.activeWorkspaceByMonitor.values.contains(home)
    }

    /// On-screen frame sits on a monitor that is NOT showing `home`.
    /// Edge strips use intersection; full windows use midpoint plus meaningful bleed on another display.
    private func frameLeaksWrongMonitor(home: String, frame: Rect) -> Bool {
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

    private func liveFrameForVisibility(_ id: WindowID) -> Rect? {
        ax.rawFrame(of: id) ?? ax.currentFrame(of: id)
    }

    private func samePidHasActiveSibling(_ id: WindowID) -> Bool {
        for other in windowsByID.keys where other.pid == id.pid && other != id {
            if let oh = authoritativeHome(for: other), isHomeActiveOnAnyMonitor(oh) {
                return true
            }
        }
        return false
    }

    /// Electron-style apps often treat AX minimize as app-wide; Safari/Chrome are per-window.
    /// When park off-screen fails (window clamps back onto another display), escalate minimize
    /// only for apps where that is safe while a sibling stays visible.
    private func allowsPerWindowMinimize(_ id: WindowID) -> Bool {
        let bid = (windowsByID[id]?.bundleID ?? "").lowercased()
        if bid.isEmpty { return true }
        if bid.contains("electron") { return false }
        if bid.hasPrefix("com.microsoft.vscode") || bid.hasPrefix("com.visualstudio.code") { return false }
        if bid.hasPrefix("com.github.atom") { return false }
        if bid.hasPrefix("com.slack.") || bid.hasPrefix("com.tinyspeck.") { return false }
        if bid.hasPrefix("com.hnc.discord") || bid.hasPrefix("com.discordapp") { return false }
        if bid.hasPrefix("com.figma.") { return false }
        if bid.hasPrefix("com.spotify.") { return false }
        return true
    }

    /// Prefer park-only while a same-PID sibling is active; escalate minimize when safe / after leak.
    private func allowMinimizeDespiteSibling(_ id: WindowID) -> Bool {
        !samePidHasActiveSibling(id) || allowsPerWindowMinimize(id)
    }

    /// Tiled window whose home is on-screen — never park/minimize (Calendar open/close loop).
    private func isActiveHomeTile(_ id: WindowID) -> Bool {
        guard let win = windowsByID[id], win.isTiled, !win.isIgnored else { return false }
        guard let home = authoritativeHome(for: id), isHomeActiveOnAnyMonitor(home) else { return false }
        return workspaces.workspaceID(containing: id) == home
    }

    /// Park (and escalate minimize for Safari-like apps) when leaving a workspace.
    private func hideOutgoingWindow(_ id: WindowID, frame: Rect, allMonitorFrames: [Rect]) {
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

    /// Repark hidden same-PID windows (Safari) that still bleed as edge strips onto another display.
    private func reparkSamePidEdgeLeaks(on monitors: [Rect]) {
        tuckWindowsLeakingWrongMonitor(preferredMonitorFrame: monitors.first)
    }

    /// Park any tracked window whose live frame is visible on a monitor not showing its sticky home.
    private func tuckWindowsLeakingWrongMonitor(preferredMonitorFrame: Rect? = nil, onlyOnMonitor: MonitorInfo? = nil) {
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

    private func frameIsOnMonitorShowingHome(home: String, frame: Rect) -> Bool {
        let monitorFrames = monitors.monitors.map(\.frame)
        guard OffscreenParking.isUsableOnscreenFrame(frame, monitors: monitorFrames) else { return false }
        guard let mon = monitors.monitorContaining(pointX: frame.midX, pointY: frame.midY) else { return false }
        return workspaces.activeWorkspaceByMonitor[mon.id] == home
    }

    private func floatFrameForActiveHome(
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

    /// Drop column slots that no longer match sticky home or live tracking.
    private func ejectWindowsListedOutsideStickyHome() -> Set<String> {
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

    private func healStaleColumnEntries() {
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

    /// Tiled windows missing from every column must be put back — otherwise visibility
    /// used to assign each the full usable rect and they piled up overlapping.
    private func reinsertOrphanTiles() {
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

    /// Show only windows belonging to currently active workspaces; park+minimize the rest.
    private func applyWorkspaceVisibility(animated: Bool) {
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
                    if !self.visibilityForceReveal,
                       self.ax.isSettled(id: id, frame: target, monitors: allMonitorFrames),
                       !(self.authoritativeHome(for: id).map { self.frameLeaksWrongMonitor(home: $0, frame: self.liveFrameForVisibility(id) ?? target) } ?? false) {
                        self.lastFrames[id] = target
                        continue
                    }
                    self.ax.reveal(frame: target, id: id)
                    if let live = self.ax.currentFrame(of: id),
                       !OffscreenParking.isUsableOnscreenFrame(live, monitors: allMonitorFrames) {
                        self.ax.reveal(frame: target, id: id)
                    }
                    self.lastFrames[id] = self.ax.currentFrame(of: id) ?? target
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

    private func refreshBorder() {
        guard configStore.config.settings.borders.enabled else {
            border.hide()
            return
        }
        let mainHeight = Double(NSScreen.screens.first?.frame.height ?? 900)
        guard let mon = primaryMonitor() else {
            border.hide()
            return
        }

        // Prefer AX focus when it is a float/dialog or belongs to the active workspace.
        let focused: WindowID? = {
            if let axID = axFocusedWindowID ?? ax.frontmostFocusedWindowID(),
               let win = windowsByID[axID],
               !win.isIgnored {
                if win.isFloating || win.isScratchpad { return axID }
                if windowIsOnActiveWorkspace(axID, monitor: mon) { return axID }
            }
            return workspaces.activeWorkspace(for: mon.id)?.focusedWindowID
        }()

        guard let focused else {
            border.hide()
            return
        }
        // Quake scratchpad: no focus ring (drops from the edge like a HUD).
        if focused == quake.windowID {
            border.hide()
            return
        }
        // Always hug the live AX chrome — tile targets often oversize apps that refuse the
        // exact frame (Electron/WhatsApp), which left the stroke floating outside the window.
        let frame = ax.currentFrame(of: focused) ?? windowsByID[focused]?.frame
        let monitors = monitors.monitors.map(\.frame)
        guard let frame,
              OffscreenParking.isUsableOnscreenFrame(frame, monitors: monitors)
        else {
            border.hide()
            return
        }
        border.show(
            around: frame,
            windowNumber: focused.windowNumber,
            monitors: monitors,
            monitorMainHeight: mainHeight
        )
    }

    /// Coalesce chrome rebuilds — AX churn after screen capture used to recreate the
    /// workspace bar every tick and eat clicks (plus peg the CPU on status-item drawing).
    private var chromeRefreshWorkItem: DispatchWorkItem?

    private func refreshChrome() {
        chromeRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshChromeNow()
        }
        chromeRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func refreshChromeNow() {
        let mainHeight = Double(NSScreen.screens.first?.frame.height ?? 900)
        let barSettings = configStore.config.settings.workspaceBar
        refreshStatusItem()
        if barSettings.enabled {
            // Soft-missing / AX churn ghosts must never keep workspace icons (Safari on WS2
            // while only Cursor is tiled). Floats still reach the ⌀ chip via the same filter.
            let barWindows = windowsByID.filter { id, _ in
                missingScanCounts[id] == nil
            }
            bar.render(
                monitors: monitors.monitors,
                definitions: configStore.config.workspaces,
                activeByMonitor: workspaces.activeWorkspaceByMonitor,
                workspaces: workspaces.workspaces,
                windowsByID: barWindows,
                windowWorkspace: windowWorkspace,
                settings: barSettings,
                mainHeight: mainHeight,
                avoidRect: statusItemScreenFrame(),
                pluginItems: PluginManager.shared.barItemsSnapshot()
            )
        } else {
            bar.hideAll()
        }
        refreshBorder()
    }

    public func dumpRuntimeState() {
        guard configStore.config.settings.developerMode else {
            NSLog("ALWM: enable developerMode to dump runtime state")
            return
        }
        var lines: [String] = []
        lines.append("ALWM runtime dump")
        lines.append("monitors=\(monitors.monitors.count)")
        lines.append("windows=\(windowsByID.count)")
        lines.append("quake=\(quake.windowID?.token ?? "nil") visible=\(quake.isVisible)")
        for mon in monitors.monitors {
            let active = workspaces.activeWorkspaceByMonitor[mon.id] ?? "?"
            lines.append("monitor \(mon.id) active=\(active) frame=\(mon.frame)")
        }
        for (id, ws) in workspaces.workspaces.sorted(by: { $0.key < $1.key }) {
            let cols = ws.columns.map { col in col.windows.map(\.token).joined(separator: ",") }.joined(separator: " | ")
            lines.append("ws \(id) '\(ws.name)' focusCol=\(ws.focusedColumn) offset=\(ws.viewOffset) cols=[\(cols)]")
        }
        for (id, frame) in lastFrames.sorted(by: { $0.key.token < $1.key.token }) {
            lines.append("frame \(id.token) \(frame)")
        }
        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        NSLog("%@", text)
    }
}

/// NSEvent monitors without capturing MainActor self.
private final class AppKitEventMonitorBridge: @unchecked Sendable {
    private let handler: @MainActor () -> Void

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
private final class StatusItemClickBridge: NSObject {
    private let onClick: (NSStatusBarButton) -> Void

    init(onClick: @escaping (NSStatusBarButton) -> Void) {
        self.onClick = onClick
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        onClick(sender)
    }
}
