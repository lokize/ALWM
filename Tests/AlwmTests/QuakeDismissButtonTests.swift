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
        let button = try #require(panel.contentView as? NSButton)
        var dismissed = false
        quake.onDismiss = { [weak quake] in
            dismissed = true
            quake?.setVisibleForRecovery(false)
        }
        button.performClick(nil)
        #expect(dismissed)
        #expect(!quake.hasVisibleDismissButton)
    }
}
