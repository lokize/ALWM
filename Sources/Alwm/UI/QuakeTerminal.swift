import AppKit
import CoreGraphics
import Foundation

@MainActor
public final class QuakeTerminalController {
    public private(set) var windowID: WindowID?
    public private(set) var isVisible = false
    public var onNeedRescan: (() -> Void)?
    /// Called whenever a window is adopted as the Quake scratchpad (float + dock).
    public var onAdopted: ((WindowID) -> Void)?
    /// Fires whenever `isVisible` changes (show/hide).
    public var onVisibilityChanged: ((Bool) -> Void)?
    /// Bundle ID waiting for the next new window to become the quake scratchpad.
    public private(set) var pendingAdoptBundleID: String?

    private var blurPanel: NSWindow?
    private weak var blurTintView: NSView?
    private var pendingLaunch = false
    private var pendingLaunchStartedAt: CFAbsoluteTime = 0
    /// Bumps on every show/hide so delayed animation steps cannot revive a dismissed panel.
    private var presentationGeneration: UInt64 = 0

    public init() {}

    public var debugDescription: String {
        "id=\(windowID?.token ?? "nil") visible=\(isVisible) pending=\(pendingLaunch) pendingBundle=\(pendingAdoptBundleID ?? "nil")"
    }

    /// Reattach a known scratchpad id without showing (bootstrap / ingest).
    public func rebind(_ id: WindowID) {
        windowID = id
        pendingAdoptBundleID = nil
    }

    public func clearPendingAdopt() {
        pendingAdoptBundleID = nil
    }

    public static func resolveBundleID(configured: String) -> String {
        if !configured.isEmpty {
            return configured
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil {
            return "com.mitchellh.ghostty"
        }
        return "com.apple.Terminal"
    }

    public func toggle(
        settings: QuakeSettings,
        monitor: MonitorInfo,
        windows: [WindowID: ManagedWindow],
        ax: AXTracker,
        applyFrame: @escaping @Sendable (WindowID, Rect) -> Void,
        focusTiled: @escaping @Sendable () -> Void
    ) {
        guard settings.enabled else {
            NSLog("ALWM Quake: toggle ignored (disabled)")
            return
        }
        let bundleID = Self.resolveBundleID(configured: settings.bundleID)
        QuakeShellAppearance.sync(bundleID: bundleID, settings: settings)
        NSLog(
            "ALWM Quake: toggle bundle=%@ id=%@ visible=%@ pending=%@ opacity=%.2f",
            bundleID,
            windowID?.token ?? "nil",
            isVisible ? "yes" : "no",
            pendingLaunch ? "yes" : "no",
            settings.effectiveOpacity
        )

        if let id = windowID {
            // Off-screen park can drop out of one AX snapshot — rescan before giving up.
            if windows[id] == nil && ax.currentAX[id] == nil {
                onNeedRescan?()
            }
            if windows[id] != nil || ax.currentAX[id] != nil {
                if isVisible {
                    NSLog("ALWM Quake: hide %@", id.token)
                    hide(id: id, settings: settings, monitor: monitor, applyFrame: applyFrame)
                    focusTiled()
                } else {
                    NSLog("ALWM Quake: show existing %@", id.token)
                    show(id: id, settings: settings, monitor: monitor, applyFrame: applyFrame, ax: ax)
                }
                return
            }
            NSLog("ALWM Quake: stale id %@ — clearing", id.token)
            windowID = nil
            setVisible(false)
        }

        // Prefer an already-adopted scratchpad — never yank a normal tiled/floating shell.
        if let existing = windows.values.first(where: {
            $0.bundleID == bundleID && $0.isScratchpad
        }) {
            NSLog("ALWM Quake: adopt scratchpad %@", existing.id.token)
            adopt(existing.id, settings: settings, monitor: monitor, applyFrame: applyFrame, ax: ax)
            return
        }

        if pendingLaunch {
            let age = CFAbsoluteTimeGetCurrent() - pendingLaunchStartedAt
            if age < 5 {
                NSLog("ALWM Quake: launch already pending (%.1fs)", age)
                return
            }
            NSLog("ALWM Quake: clearing stuck pendingLaunch (%.1fs)", age)
            pendingLaunch = false
        }
        pendingLaunch = true
        pendingLaunchStartedAt = CFAbsoluteTimeGetCurrent()
        pendingAdoptBundleID = bundleID
        NSLog("ALWM Quake: launching dedicated scratchpad for %@", bundleID)
        launchNewWindow(bundleID: bundleID, settings: settings) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.pendingLaunch = false }
                self.onNeedRescan?()
                for attempt in 0..<8 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    self.onNeedRescan?()
                    if let found = self.pickNewestWindow(bundleID: bundleID, in: ax) {
                        NSLog("ALWM Quake: found %@ attempt %d", found.token, attempt)
                        self.adopt(found, settings: settings, monitor: monitor, applyFrame: applyFrame, ax: ax)
                        return
                    }
                }
                self.pendingAdoptBundleID = nil
                NSLog("ALWM Quake: could not find window for %@", bundleID)
            }
        }
    }

    private func adopt(
        _ id: WindowID,
        settings: QuakeSettings,
        monitor: MonitorInfo,
        applyFrame: @escaping @Sendable (WindowID, Rect) -> Void,
        ax: AXTracker
    ) {
        windowID = id
        pendingAdoptBundleID = nil
        onAdopted?(id)
        // Caller may still be outside the suppress window — extend while we animate in.
        show(id: id, settings: settings, monitor: monitor, applyFrame: applyFrame, ax: ax)
        // Re-assert docked float after AX/app settle.
        let frame = visibleFrame(settings: settings, monitor: monitor)
        applyFrame(id, frame)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.windowID == id, self.isVisible else { return }
            applyFrame(id, frame)
            ax.focus(id)
        }
    }

    public func markScratchpad(in windows: inout [WindowID: ManagedWindow]) {
        guard let id = windowID, var win = windows[id] else { return }
        win.isScratchpad = true
        win.isFloating = true
        windows[id] = win
    }

    /// Visible float frame docked to the configured edge.
    public func visibleFrame(settings: QuakeSettings, monitor: MonitorInfo) -> Rect {
        let mon = monitor.frame
        let inset = max(0, settings.inset)
        let sizeRatio = min(0.95, max(0.15, settings.sizeRatio))
        let lengthRatio = min(1.0, max(0.2, settings.lengthRatio))

        switch settings.edge {
        case .top:
            let height = max(160, mon.height * sizeRatio)
            let width = max(200, (mon.width - inset * 2) * lengthRatio)
            let x = mon.x + inset + ((mon.width - inset * 2) - width) / 2
            return Rect(x: x, y: mon.y + inset, width: width, height: height)
        case .bottom:
            let height = max(160, mon.height * sizeRatio)
            let width = max(200, (mon.width - inset * 2) * lengthRatio)
            let x = mon.x + inset + ((mon.width - inset * 2) - width) / 2
            return Rect(x: x, y: mon.maxY - height - inset, width: width, height: height)
        case .left:
            let width = max(200, mon.width * sizeRatio)
            let height = max(160, (mon.height - inset * 2) * lengthRatio)
            let y = mon.y + inset + ((mon.height - inset * 2) - height) / 2
            return Rect(x: mon.x + inset, y: y, width: width, height: height)
        case .right:
            let width = max(200, mon.width * sizeRatio)
            let height = max(160, (mon.height - inset * 2) * lengthRatio)
            let y = mon.y + inset + ((mon.height - inset * 2) - height) / 2
            return Rect(x: mon.maxX - width - inset, y: y, width: width, height: height)
        }
    }

    public func hiddenFrame(settings: QuakeSettings, monitor: MonitorInfo) -> Rect {
        let visible = visibleFrame(settings: settings, monitor: monitor)
        let mon = monitor.frame
        switch settings.edge {
        case .top:
            return Rect(x: visible.x, y: mon.y - visible.height - 40, width: visible.width, height: visible.height)
        case .bottom:
            return Rect(x: visible.x, y: mon.maxY + 40, width: visible.width, height: visible.height)
        case .left:
            return Rect(x: mon.x - visible.width - 40, y: visible.y, width: visible.width, height: visible.height)
        case .right:
            return Rect(x: mon.maxX + 40, y: visible.y, width: visible.width, height: visible.height)
        }
    }

    private func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        onVisibilityChanged?(visible)
    }

    /// Restore visibility after a false AX destroy / window-number churn without re-running show animation.
    public func setVisibleForRecovery(_ visible: Bool) {
        setVisible(visible)
        if !visible {
            blurPanel?.orderOut(nil)
        }
    }

    private func show(
        id: WindowID,
        settings: QuakeSettings,
        monitor: MonitorInfo,
        applyFrame: @escaping @Sendable (WindowID, Rect) -> Void,
        ax: AXTracker
    ) {
        presentationGeneration &+= 1
        let visible = visibleFrame(settings: settings, monitor: monitor)
        QuakeShellAppearance.sync(
            bundleID: Self.resolveBundleID(configured: settings.bundleID),
            settings: settings
        )
        updateBlur(settings: settings, frame: visible, monitor: monitor, visible: true)
        setVisible(true)

        // Snap open (no multi-step lerp). Mid-animation AX + applyWorkspaceVisibility used to
        // fight each other and leave siblings half-height / Quake stuck mid-slide.
        applyFrame(id, visible)
        ax.setMinimized(false, id: id)
        ax.focus(id)
        NSLog("ALWM Quake: show %@ edge=%@ opacity=%.2f blur=%@ frame=(%.0f,%.0f %.0fx%.0f)",
              id.token, settings.edge.rawValue, settings.effectiveOpacity,
              settings.blur ? "on" : "off",
              visible.x, visible.y, visible.width, visible.height)
    }

    private func hide(
        id: WindowID,
        settings: QuakeSettings,
        monitor: MonitorInfo,
        applyFrame: @escaping @Sendable (WindowID, Rect) -> Void
    ) {
        presentationGeneration &+= 1
        let hidden = hiddenFrame(settings: settings, monitor: monitor)
        setVisible(false)
        updateBlur(settings: settings, frame: Rect(x: 0, y: 0, width: 0, height: 0), monitor: monitor, visible: false)
        applyFrame(id, hidden)
    }

    private func updateBlur(
        settings: QuakeSettings,
        frame: Rect,
        monitor: MonitorInfo,
        visible: Bool
    ) {
        guard settings.blur, visible, frame.width > 1, frame.height > 1 else {
            blurPanel?.orderOut(nil)
            return
        }

        let mainH = Double(NSScreen.screens.first?.frame.height ?? CGFloat(monitor.frame.height))
        let cocoaY = mainH - frame.y - frame.height
        let pad: CGFloat = 10
        let rect = NSRect(
            x: frame.x - Double(pad),
            y: cocoaY - Double(pad),
            width: frame.width + Double(pad) * 2,
            height: frame.height + Double(pad) * 2
        )

        let panel = blurPanel ?? makeBlurPanel()
        blurPanel = panel
        applyBlurIntensity(settings.blurIntensity, to: panel)
        panel.setFrame(rect, display: true)
        if let root = panel.contentView {
            root.frame = NSRect(origin: .zero, size: rect.size)
            for sub in root.subviews {
                sub.frame = root.bounds
            }
        }
        // Stay under typical terminal chrome without order(relativeTo:) on a foreign
        // CGWindowID — that AppKit API is only valid for NSWindows in this process.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.normalWindow)) - 1)
        panel.orderFrontRegardless()
    }

    /// Re-apply blur while Quake is already visible (Settings live update).
    public func refreshBlur(
        settings: QuakeSettings,
        monitor: MonitorInfo,
        frame: Rect
    ) {
        let bundle = Self.resolveBundleID(configured: settings.bundleID)
        QuakeShellAppearance.sync(bundleID: bundle, settings: settings)
        updateBlur(
            settings: settings,
            frame: frame,
            monitor: monitor,
            visible: isVisible
        )
    }

    private func applyBlurIntensity(_ intensity: Double, to panel: NSWindow) {
        let t = min(1, max(0, intensity))
        // Keep the panel fully present — opacity of the *terminal* reveals the blur.
        // Vary material + light tint only (old code set panel.alphaValue→1 which looked solid).
        panel.alphaValue = 1

        guard let root = panel.contentView else { return }
        let effect = (root as? NSVisualEffectView)
            ?? root.subviews.compactMap { $0 as? NSVisualEffectView }.first
        effect?.state = .active
        effect?.blendingMode = .behindWindow

        switch t {
        case ..<0.34:
            effect?.material = .sheet
        case ..<0.67:
            effect?.material = .hudWindow
        default:
            effect?.material = .fullScreenUI
        }
        // Light tint so wallpaper still reads through the glass.
        blurTintView?.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08 + 0.22 * t).cgColor
    }

    private func makeBlurPanel() -> NSWindow {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView(frame: .zero)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]

        let tint = NSView(frame: .zero)
        tint.wantsLayer = true
        tint.layer?.cornerRadius = 12
        tint.layer?.masksToBounds = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        tint.autoresizingMask = [.width, .height]

        effect.addSubview(tint)
        blurTintView = tint
        panel.contentView = effect
        return panel
    }

    /// Open a *new* terminal window (do not just activate an existing tiled one).
    private func launchNewWindow(bundleID: String, settings: QuakeSettings, completion: @escaping @Sendable () -> Void) {
        QuakeShellAppearance.sync(bundleID: bundleID, settings: settings)
        switch bundleID {
        case "com.apple.Terminal":
            let script = """
            tell application "Terminal"
              activate
              do script ""
            end tell
            """
            runAppleScript(script, completion: completion)
        case "com.mitchellh.ghostty":
            // Avoid AppleScript/System Events — they can hang forever and freeze ALWM.
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                app.activate(options: [.activateIgnoringOtherApps])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    Self.postCommandN()
                    completion()
                }
            } else {
                openApplication(bundleID: bundleID, completion: completion)
            }
        default:
            openApplication(bundleID: bundleID, completion: completion)
        }
    }

    private func openApplication(bundleID: String, completion: @escaping @Sendable () -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            completion()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func runAppleScript(_ source: String, completion: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let script = NSAppleScript(source: source)
            let box = NSMutableDictionary()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                var localError: NSDictionary?
                script?.executeAndReturnError(&localError)
                if let localError { box["error"] = localError }
                group.leave()
            }
            if group.wait(timeout: .now() + 2.5) == .timedOut {
                NSLog("ALWM Quake: AppleScript timed out")
            } else if let error = box["error"] as? NSDictionary {
                NSLog("ALWM Quake AppleScript error: %@", error)
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    private static func postCommandN() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x2D, keyDown: true) // n
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x2D, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func pickNewestWindow(bundleID: String, in ax: AXTracker) -> WindowID? {
        let matches = ax.currentWindows.filter { $0.bundleID == bundleID && !$0.isIgnored }
        // Highest windowNumber is usually the newest.
        return matches.max(by: { $0.id.windowNumber < $1.id.windowNumber })?.id
    }

    public func forgetIfGone(windows: [WindowID: ManagedWindow]) {
        guard let id = windowID else { return }
        // Keep the scratchpad identity while intentionally hidden — offscreen park
        // often drops out of a single AX scan; clearing here would launch a new shell.
        if windows[id] != nil { return }
        if !isVisible { return }
        windowID = nil
        setVisible(false)
        blurPanel?.orderOut(nil)
    }

    /// Drop the binding only after the window is confirmed gone from tracking (soft-delete done).
    public func forgetIfFullyGone(windows: [WindowID: ManagedWindow]) {
        guard let id = windowID else { return }
        guard windows[id] == nil else { return }
        windowID = nil
        setVisible(false)
        blurPanel?.orderOut(nil)
    }

    /// Slide away without destroying the terminal session (same window comes back on reopen).
    public func dismiss(
        settings: QuakeSettings,
        monitor: MonitorInfo,
        applyFrame: @escaping @Sendable (WindowID, Rect) -> Void,
        focusTiled: @escaping @Sendable () -> Void
    ) {
        guard isVisible, let id = windowID else { return }
        hide(id: id, settings: settings, monitor: monitor, applyFrame: applyFrame)
        focusTiled()
    }

    /// User closed the scratchpad window — drop binding without waiting for soft-delete scans.
    public func clearAfterUserClose() {
        windowID = nil
        setVisible(false)
        pendingLaunch = false
        pendingAdoptBundleID = nil
        blurPanel?.orderOut(nil)
    }

    public func hideBlur() {
        blurPanel?.orderOut(nil)
    }
}
