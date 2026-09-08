import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC
import AlwmPluginAPI

// MARK: - Lifecycle — status item, settings UI helpers, permissions

extension WindowManager {
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

    func applyAppearanceTheme(_ theme: AppTheme) {
        switch theme {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func syncWorkspacesToMonitors() {
        workspaces.configure(definitions: configStore.config.workspaces, monitors: monitors.monitors)
        primaryMonitorID = monitors.monitors.first?.id ?? 0
    }

    func setupStatusItem() {
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

    func refreshStatusPopover() {
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

    func statusBarWindowLabel() -> String {
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

    func statusBarFocusedWindow() -> ManagedWindow? {
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

    func windowIsOnActiveWorkspace(_ id: WindowID, monitor: MonitorInfo) -> Bool {
        guard let activeID = workspaces.activeWorkspaceByMonitor[monitor.id] else { return false }
        if workspaces.workspaceID(containing: id) == activeID { return true }
        return windowWorkspace[id] == activeID
    }

    func statusItemScreenFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let inWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(inWindow)
    }

    func workspaceName(for windowID: WindowID) -> String {
        let wsID = windowWorkspace[windowID]
            ?? workspaces.workspaceID(containing: windowID)
            ?? {
                guard let mon = monitorUnderMouse() ?? primaryMonitor() else { return nil }
                return workspaces.activeWorkspaceByMonitor[mon.id]
            }()
        guard let wsID, let ws = workspaces.workspaces[wsID] else { return "—" }
        return ws.name.isEmpty ? ws.id : ws.name
    }

    func monitorUnderMouse() -> MonitorInfo? {
        let p = NSEvent.mouseLocation
        let mainH = Double(NSScreen.screens.first?.frame.height ?? 0)
        // Cocoa bottom-left → AX top-left used by MonitorStore frames.
        let axY = mainH - Double(p.y)
        return monitors.monitorContaining(pointX: Double(p.x), pointY: axY)
    }

    func mutateSettings(_ body: (inout LayoutSettings) -> Void) {
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

    func resetRuntimeState() {
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

    func notifyPluginAutoDisabled(_ id: String) {
        let name = PluginManager.shared.catalog.first(where: { $0.id == id })?.manifest.name ?? id
        let alert = NSAlert()
        alert.messageText = L10n.t("plugins.load_failed.title")
        alert.informativeText = String(format: L10n.t("plugins.load_failed.body"), name)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L10n.t("plugins.load_failed.open_settings"))
        DispatchQueue.main.async {
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                self.handleAction("settings.open.plugins")
            }
        }
    }

    func restorePersistedWorkspaces() {
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

    func activateFirstWorkspaceOnAllMonitors() {
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

    func firstWorkspaceID() -> String? {
        if workspaces.workspaces["1"] != nil { return "1" }
        return configStore.config.workspaces.first?.id ?? workspaces.workspaces.keys.sorted().first
    }

    func showOnboardingAlert() {
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


    func refreshStatusItem() {
        refreshStatusPopover()
        guard let item = statusItem else { return }
        let settings = configStore.config.settings
        // Workspace bar already shows chips (+ optional focused status). Don't duplicate
        // the same workspace/window label in the system menu bar.
        let showLabel = settings.showMenuBarStatusLabel && !settings.workspaceBar.enabled
        let label = showLabel ? statusBarWindowLabel() : ""
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
}
