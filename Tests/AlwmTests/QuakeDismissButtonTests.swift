import AppKit
import Testing
@testable import Alwm

@Suite("Quake dismissal chrome")
struct QuakeDismissButtonTests {
    @Test("persistent terminal shows a dismiss button even without blur")
    @MainActor
    func persistentTerminalHasDismissButton() throws {
        let quake = QuakeTerminalController()
        var settings = QuakeSettings.default
        settings.blur = false
        settings.dismissOnClickOutside = false
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        quake.setVisibleForRecovery(true)
        quake.refreshBlur(settings: settings, monitor: monitor, frame: quake.visibleFrame(settings: settings, monitor: monitor))
        let visible = quake.hasVisibleDismissButton
        #expect(visible)
        let panel = try #require(NSApp.windows.first { $0.identifier?.rawValue == "alwm.quake.dismiss" && $0.isVisible })
        #expect(!AlwmChromeFocus.isInteractiveChrome(panel))
        let controls = try #require(panel.contentView as? NSStackView)
        #expect(controls.views.count == 3)
        #expect(quake.hasVisibleMoveButton)
        let move = try #require(controls.views.first as? NSButton)
        #expect(move.accessibilityLabel() == L10n.t("quake.move"))
        var requestedMove = false
        quake.onRequestChangeMonitorWorkspace = { _ in requestedMove = true }
        move.performClick(nil)
        #expect(requestedMove)
        let fullscreen = try #require(controls.views[1] as? NSButton)
        let button = try #require(controls.views.last as? NSButton)
        #expect(fullscreen.accessibilityLabel() == L10n.t("overlay.fullscreen.expand"))
        var expanded = false
        quake.onToggleFullscreen = { expanded = true }
        fullscreen.performClick(nil)
        #expect(expanded)
        var dismissed = false
        quake.onDismiss = { [weak quake] in
            dismissed = true
            quake?.setVisibleForRecovery(false)
        }
        button.performClick(nil)
        #expect(dismissed)
        #expect(!quake.hasVisibleDismissButton)
    }

    @Test("top-edge overlay controls stay below the macOS menu bar")
    func topEdgeControlsClearMenuBar() {
        let frame = Rect(x: 0, y: 0, width: 1440, height: 900)
        let controls = OverlayChromeGeometry.controlPanelFrame(
            overlayFrame: frame,
            mainScreenHeight: 900,
            topSafeInset: 24
        )

        #expect(controls.maxY <= 900 - 24)
        #expect(controls.width == 92)
        #expect(controls.height == 28)
        #expect(OverlayChromeGeometry.notepadTopChromeInset(isFullscreen: true, topSafeInset: 24) >= 28)
        #expect(OverlayChromeGeometry.notepadTopChromeInset(isFullscreen: false, topSafeInset: 24) == 0)
    }

    @Test("quake location is maintained and can be updated")
    @MainActor
    func quakeLocationMaintained() {
        let quake = QuakeTerminalController()
        #expect(quake.activeMonitorID == nil)
        #expect(quake.activeWorkspaceID == nil)

        quake.setLocation(monitorID: 10, workspaceID: "3")
        #expect(quake.activeMonitorID == 10)
        #expect(quake.activeWorkspaceID == "3")

        quake.setLocation(monitorID: 20, workspaceID: "5")
        #expect(quake.activeMonitorID == 20)
        #expect(quake.activeWorkspaceID == "5")

        // Clearing after user close resets location
        quake.clearAfterUserClose()
        #expect(quake.activeMonitorID == nil)
        #expect(quake.activeWorkspaceID == nil)
    }
}
