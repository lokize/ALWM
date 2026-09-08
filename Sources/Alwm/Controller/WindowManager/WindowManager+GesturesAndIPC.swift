import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC
import AlwmPluginAPI

// MARK: - Gestures, command actions, and IPC

extension WindowManager {
    func setupGestures() {
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

    func handleGestureSignal(_ signal: GestureScrollMonitor.Signal) {
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

    func dominantDiscreteDirection(
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

    func notePanVelocity(_ delta: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        let dt = max(1.0 / 240.0, now - gesturePanSampleAt)
        let instant = delta / dt
        gesturePanVelocity = gesturePanSampleAt == 0
            ? instant
            : gesturePanVelocity * 0.55 + instant * 0.45
        gesturePanSampleAt = now
    }

    func applyContinuousColumnScroll(delta: Double, fromFinger: Bool) {
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

    func applyContinuousStackScroll(delta: Double, fromFinger: Bool) {
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

    func applyActiveWorkspaceFramesFast(on monitor: MonitorInfo) {
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

    func finishContinuousColumnScroll() {
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

    func startGestureInertia(velocity: Double) {
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

    func settleContinuousGesture() {
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

    func snapGestureScroll() {
        // Legacy entry — settle with snap.
        gesturePanKind = .columns
        settleContinuousGesture()
    }

    func scheduleGestureScrollFinish() {
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

    func startIPC() throws {
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

    func handleIPC(_ request: IPCRequest) -> IPCResponse {
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

}
