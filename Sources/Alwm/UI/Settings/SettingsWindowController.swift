import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - Settings window controller

@MainActor
public final class SettingsWindowController {
    var window: NSWindow?
    var closeObserver: NSObjectProtocol?
    /// Separate from `window` so close/teardown can mutate the window without
    /// overlapping exclusivity when `isVisible` is read from persist → applyConfig.
    var presented = false
    public var onSave: ((AlwmConfig) -> Void)?
    public var onDump: (() -> Void)?
    public var onRevealConfig: (() -> Void)?
    public var onResetRuntime: (() -> Void)?
    public var onRerunOnboarding: (() -> Void)?
    public var monitorsProvider: (() -> [MonitorInfo])?
    public var runningAppsProvider: (() -> [AppRuleRunningApp])?
    public var onCaptureAppRuleFrame: ((String?) -> AppRuleCapturedGeometry?)?
    public var onApplyRulesNow: (() -> Void)?
    /// Fired when Settings becomes visible (`true`) or is dismissed (`false`).
    /// Used to pause focus-follows-mouse + hide the focus border (same as palette/plugins).
    public var onVisibilityChange: ((Bool) -> Void)?

    public init() {}

    public func open(config: AlwmConfig, initialPane: String? = nil) {
        let pane = SettingsPane(rawValue: initialPane ?? "") ?? .general
        // Always rebuild so toggles reflect the live config (not a stale copy).
        if window != nil || presented {
            tearDownPresentedWindow(notifyHidden: true)
        }
        detachCloseObserver()
        let root = SettingsRootView(
            config: config,
            initialPane: pane,
            monitors: monitorsProvider?() ?? [],
            runningAppsProvider: { [weak self] in self?.runningAppsProvider?() ?? [] },
            onCaptureAppRuleFrame: { [weak self] bundleID in self?.onCaptureAppRuleFrame?(bundleID) },
            onApplyRulesNow: { [weak self] in self?.onApplyRulesNow?() },
            onSave: { [weak self] c in self?.onSave?(c) },
            onDump: { [weak self] in self?.onDump?() },
            onRevealConfig: { [weak self] in self?.onRevealConfig?() },
            onResetRuntime: { [weak self] in self?.onResetRuntime?() },
            onRerunOnboarding: { [weak self] in self?.onRerunOnboarding?() }
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.t("settings.title")
        window.setContentSize(NSSize(width: 1100, height: 780))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 960, height: 680)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        presented = true
        onVisibilityChange?(true)
        PluginPanelOutsideClick.watch(window) { [weak self] in
            self?.close()
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // Stay synchronous on the main queue — a nested Task { @MainActor }
            // raced with NSWindow dealloc → persist → isVisible (Swift exclusivity abort).
            MainActor.assumeIsolated {
                self?.handleWindowWillClose()
            }
        }
    }

    public func close() {
        tearDownPresentedWindow(notifyHidden: true, orderOut: true)
    }

    /// True only while Settings is the key window (do not block gestures when it sits in the background).
    public var isKeyFront: Bool {
        guard presented, let window, window.isVisible else { return false }
        return window.isKeyWindow
    }

    /// True while the settings window is on screen (blocks focus-follows-mouse).
    /// Uses `presented` — never reads `window` during teardown exclusivity windows.
    public var isVisible: Bool { presented }

    func handleWindowWillClose() {
        tearDownPresentedWindow(notifyHidden: true, orderOut: false)
    }

    /// Clear presentation state before releasing `window` so re-entrant
    /// `isVisible` / `refreshBorder` during dealloc cannot conflict.
    func tearDownPresentedWindow(notifyHidden: Bool, orderOut: Bool = true) {
        let wasPresented = presented || window != nil
        presented = false
        let closing = window
        PluginPanelOutsideClick.stop(for: closing)
        detachCloseObserver()
        window = nil
        if orderOut {
            closing?.orderOut(nil)
        }
        if notifyHidden, wasPresented {
            onVisibilityChange?(false)
        }
    }

    func detachCloseObserver() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }
}

