import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC
import AlwmPluginAPI

// MARK: - Overlays — Quake terminal and Notepad

extension WindowManager {
    func isQuakeOwned(_ id: WindowID) -> Bool {
        if id == quake.windowID { return true }
        return runtimeState.snapshot.quakeWindowToken == id.token
    }

    func quakeSessionPID() -> pid_t? {
        if let id = quake.windowID { return id.pid }
        if let token = runtimeState.snapshot.quakeWindowToken,
           let sep = token.firstIndex(of: ":"),
           let pid = pid_t(token[..<sep]) {
            return pid
        }
        return nil
    }

    func quakeSessionBundleID() -> String? {
        if let pending = quake.pendingAdoptBundleID, !pending.isEmpty { return pending }
        if let id = quake.windowID, let bid = windowsByID[id]?.bundleID, !bid.isEmpty {
            return bid
        }
        if let token = runtimeState.snapshot.quakeWindowToken,
           let win = windowsByID.first(where: { $0.key.token == token })?.value,
           let bid = win.bundleID, !bid.isEmpty {
            return bid
        }
        if quake.windowID != nil || quake.isVisible || runtimeState.snapshot.quakeWindowToken != nil {
            return QuakeTerminalController.resolveBundleID(
                configured: configStore.config.settings.quake.bundleID
            )
        }
        return nil
    }

    func isQuakeShellApp(_ win: ManagedWindow) -> Bool {
        guard let sessionBundle = quakeSessionBundleID() else {
            let bid = win.bundleID ?? ""
            return bid == "com.mitchellh.ghostty" || bid == "com.apple.Terminal"
                || Self.appNameMatchesQuakeBundle(win.appName, bundleID: "com.mitchellh.ghostty")
                || Self.appNameMatchesQuakeBundle(win.appName, bundleID: "com.apple.Terminal")
        }
        let bid = win.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bid == sessionBundle { return true }
        if bid.isEmpty {
            return Self.appNameMatchesQuakeBundle(win.appName, bundleID: sessionBundle)
        }
        return false
    }

    func isQuakeSessionWindow(_ win: ManagedWindow) -> Bool {
        if isQuakeOwned(win.id) || quake.windowID == win.id { return true }
        if let pid = quakeSessionPID(), win.id.pid == pid, isQuakeShellApp(win) {
            return true
        }
        guard let sessionBundle = quakeSessionBundleID() else { return false }
        guard isQuakeShellApp(win) else { return false }
        // Pending launch or visible Quake: any matching shell window stays float.
        if quake.pendingAdoptBundleID != nil { return true }
        if quake.isVisible { return true }
        _ = sessionBundle
        return false
    }

    func enforceQuakeFloat() {
        // Rebind from persisted token after relaunch.
        if quake.windowID == nil, let token = runtimeState.snapshot.quakeWindowToken {
            if let id = windowsByID.keys.first(where: { $0.token == token }) {
                quake.rebind(id)
                NSLog("ALWM Quake: rebound from token %@", token)
            } else if let pid = quakeSessionPID(),
                      let id = windowsByID.keys.first(where: { $0.pid == pid }) {
                quake.rebind(id)
                runtimeState.setQuakeWindowToken(id.token)
                NSLog("ALWM Quake: rebound from session pid %d → %@", pid, id.token)
            }
        }

        guard let id = quake.windowID, var win = windowsByID[id] else {
            _ = stripQuakeSessionFromColumns()
            return
        }
        win.isFloating = true
        win.isScratchpad = true
        windowsByID[id] = win
        floatingOverrides.insert(id)
        workspaces.removeWindowEverywhere(id)
        runtimeState.setQuakeWindowToken(id.token)
        ensureFloatHome(id, win: win)
        let stripped = stripQuakeSessionFromColumns()
        if quake.isVisible {
            reassertQuakeVisibleFrame(for: id)
            if stripped {
                NSLog("ALWM Quake: reasserted float frame after stripping tiles")
            }
        }
    }

    func stripQuakeSessionFromColumns() -> Bool {
        var stripped = false
        for (id, win) in windowsByID {
            guard isQuakeSessionWindow(win) else { continue }
            if var updated = windowsByID[id] {
                updated.isFloating = true
                updated.isScratchpad = true
                windowsByID[id] = updated
            }
            floatingOverrides.insert(id)
            if workspaces.workspaceID(containing: id) != nil {
                workspaces.removeWindowEverywhere(id)
                stripped = true
                NSLog("ALWM Quake: stripped %@ from tile columns", id.token)
            }
        }
        return stripped
    }

    func stripPendingQuakeFromColumns() -> Bool {
        stripQuakeSessionFromColumns()
    }

    func recoverQuakeBindingIfNeeded(fromAdded added: Set<WindowID>) {
        if let id = quake.windowID, windowsByID[id] != nil { return }
        let sessionBundle = QuakeTerminalController.resolveBundleID(
            configured: configStore.config.settings.quake.bundleID
        )
        let candidates = windowsByID.values.filter { win in
            guard win.isScratchpad || floatingOverrides.contains(win.id) else { return false }
            let bid = win.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return bid == sessionBundle
                || Self.appNameMatchesQuakeBundle(win.appName, bundleID: sessionBundle)
        }
        guard let newest = candidates.max(by: { $0.id.windowNumber < $1.id.windowNumber }) else { return }
        // Prefer a freshly added window when the previous binding disappeared.
        let pick: ManagedWindow
        if let addedHit = candidates.first(where: { added.contains($0.id) }) {
            pick = addedHit
        } else {
            pick = newest
        }
        quake.rebind(pick.id)
        runtimeState.setQuakeWindowToken(pick.id.token)
        floatingOverrides.insert(pick.id)
        if var win = windowsByID[pick.id] {
            win.isFloating = true
            win.isScratchpad = true
            windowsByID[pick.id] = win
        }
        workspaces.removeWindowEverywhere(pick.id)
        NSLog("ALWM Quake: rebound session window %@", pick.id.token)
    }

    func setupOverlayClickOutside() {
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

    func dismissOverlaysIfClickOutside() {
        dismissQuakeIfClickOutside()
        dismissNotepadIfClickOutside()
    }

    func quakeHasKeyboardFocus() -> Bool {
        guard quake.isVisible, let qid = quake.windowID else { return false }
        if axFocusedWindowID == qid || ax.frontmostFocusedWindowID() == qid { return true }
        let configured = configStore.config.settings.quake.bundleID
        let resolved = QuakeTerminalController.resolveBundleID(configured: configured)
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == resolved { return true }
        return false
    }

    func dismissNotepadIfClickOutside() {
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

    func updateOverlayInputMode() {
        let overlayNow = overlaysCaptureFocus
        hotkeys.setOverlayKeyboardCapture(overlayNow)

        if overlayNow {
            // Stop any pending focus-follows-mouse hop onto tiles under the overlay.
            ffmWorkItem?.cancel()
            ffmWorkItem = nil
            border.hide()
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
            refreshBorder()
        }
    }

    func dismissNotepad(on monitor: MonitorInfo) {
        guard notepad.isVisible else { return }
        notepad.hide(settings: configStore.config.settings.notepad, monitor: monitor)
        updateOverlayInputMode()
    }

    func toggleNotepad(monitor: MonitorInfo) {
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

    func openNotepad(pageID: UUID) {
        guard let monitor = monitorForAction() ?? primaryMonitor() else { return }
        let settings = configStore.config.settings.notepad
        notepad.open(pageID: pageID, settings: settings, monitor: monitor)
        preferredOverlayFocus = .notepad
        suppressNotepadDismissUntil = Date().addingTimeInterval(0.5)
        updateOverlayInputMode()
    }

    func openNewNotepad(monitor: MonitorInfo) {
        let settings = configStore.config.settings.notepad
        notepad.openNew(settings: settings, monitor: monitor)
        preferredOverlayFocus = .notepad
        suppressNotepadDismissUntil = Date().addingTimeInterval(0.5)
        updateOverlayInputMode()
    }

    func dismissQuakeIfClickOutside() {
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

    func dismissQuake() {
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

    func ensureQuakeFullyHidden() {
        guard !quake.isVisible else { return }
        let monitorFrames = monitors.monitors.map(\.frame)
        guard !monitorFrames.isEmpty else { return }
        let settings = configStore.config.settings.quake
        let mon = monitors.monitors.first(where: { $0.id == primaryMonitorID })
            ?? primaryMonitor()
            ?? monitors.monitors.first
        guard let mon else { return }
        let hidden = quake.hiddenFrame(settings: settings, monitor: mon)

        func tuck(_ id: WindowID) {
            let live = ax.currentFrame(of: id) ?? windowsByID[id]?.frame
            let leaking = live.map {
                OffscreenParking.intersectsAnyMonitor($0, monitors: monitorFrames)
                    && !OffscreenParking.isUsableOnscreenFrame($0, monitors: monitorFrames)
            } ?? false
            let onScreen = live.map { OffscreenParking.isUsableOnscreenFrame($0, monitors: monitorFrames) } ?? false
            let deminiaturized = !ax.isMinimized(id)
            guard deminiaturized || leaking || onScreen else {
                lastFrames[id] = hidden
                return
            }
            ax.parkAndHide(frame: hidden, id: id, monitors: monitorFrames)
            lastFrames[id] = hidden
            quake.hideBlur()
            NSLog("ALWM Quake: tucked dismissed panel %@", id.token)
        }

        if let qid = quake.windowID {
            tuck(qid)
        }
        for (id, win) in windowsByID where isQuakeSessionWindow(win) || isQuakeOwned(id) {
            if id == quake.windowID { continue }
            tuck(id)
        }
    }

    func handleQuakeWindowClosed() {
        quakeCloseConfirmWorkItem?.cancel()
        quakeCloseConfirmWorkItem = nil
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

    func scheduleConfirmQuakeClosed(suspectID: WindowID) {
        quakeCloseConfirmWorkItem?.cancel()
        let wasVisible = quake.isVisible
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.quake.windowID == suspectID || self.isQuakeOwned(suspectID) else { return }
            self.ax.scanAll()
            let live = self.ax.currentWindows
            if live.contains(where: { $0.id == suspectID }) {
                NSLog("ALWM Quake: ignoring false AX destroy for %@", suspectID.token)
                self.missingScanCounts.removeValue(forKey: suspectID)
                if wasVisible {
                    self.reassertQuakeVisibleFrame(for: suspectID)
                }
                return
            }
            // Window number churn: same process still has a shell window.
            if let replacement = live.first(where: {
                $0.id.pid == suspectID.pid && !$0.isIgnored && $0.id != suspectID
            }) {
                NSLog(
                    "ALWM Quake: rebinding after AX churn %@ → %@",
                    suspectID.token,
                    replacement.id.token
                )
                self.adoptQuakeReplacement(replacement.id, wasVisible: wasVisible)
                return
            }
            // Also check tracked soft-missing / float pool.
            if let tracked = self.windowsByID.values.first(where: {
                $0.id.pid == suspectID.pid && $0.id != suspectID && ($0.isScratchpad || self.floatingOverrides.contains($0.id))
            }) {
                NSLog(
                    "ALWM Quake: rebinding tracked replacement %@ → %@",
                    suspectID.token,
                    tracked.id.token
                )
                self.adoptQuakeReplacement(tracked.id, wasVisible: wasVisible)
                return
            }
            NSLog("ALWM Quake: confirmed closed %@", suspectID.token)
            self.handleQuakeWindowClosed()
            self.persistRuntimeState()
            self.refreshChrome()
        }
        quakeCloseConfirmWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func adoptQuakeReplacement(_ id: WindowID, wasVisible: Bool) {
        floatingOverrides.insert(id)
        if var win = windowsByID[id] {
            win.isFloating = true
            win.isScratchpad = true
            windowsByID[id] = win
        }
        workspaces.removeWindowEverywhere(id)
        quake.rebind(id)
        runtimeState.setQuakeWindowToken(id.token)
        missingScanCounts.removeValue(forKey: id)
        suppressQuakeDismissUntil = Date().addingTimeInterval(0.8)
        if wasVisible {
            quake.setVisibleForRecovery(true)
            reassertQuakeVisibleFrame(for: id)
            preferredOverlayFocus = .quake
        }
        updateOverlayInputMode()
        persistRuntimeState()
        refreshChrome()
    }

    func reassertQuakeVisibleFrame(for id: WindowID) {
        guard let monitor = primaryMonitor() ?? monitors.monitors.first else { return }
        let settings = configStore.config.settings.quake
        let frame = quake.visibleFrame(settings: settings, monitor: monitor)
        ax.setMinimized(false, id: id)
        ax.apply(frame: frame, to: id)
        ax.focus(id)
        lastFrames[id] = frame
        quake.refreshBlur(settings: settings, monitor: monitor, frame: frame)
    }

    func toggleQuake(monitor: MonitorInfo) {
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

}
