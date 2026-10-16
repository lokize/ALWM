import CoreGraphics
import Testing
@testable import Alwm

@Suite("Focus follows mouse border routing")
struct FocusBorderPolicyTests {
    @Test("the border follows the mouse-focused window while AX focus is stale")
    func mouseFocusWinsOverStaleAccessibilityFocus() {
        let oldAXWindow = WindowID(pid: 10, windowNumber: 100)
        let hoveredWindow = WindowID(pid: 20, windowNumber: 200)
        #expect(FocusBorderPolicy.focusedWindow(
            mouseFocusedWindow: hoveredWindow,
            accessibilityFocusedWindow: oldAXWindow,
            logicalWorkspaceFocusedWindow: oldAXWindow,
            focusSourceIsMouse: true
        ) == hoveredWindow)
    }

    @Test("the focus ring follows the active workspace display instead of a stale primary display")
    func borderUsesDisplayHostingFocusedWorkspace() {
        let msi: CGDirectDisplayID = 2
        let hdmi: CGDirectDisplayID = 3
        let selected = FocusBorderPolicy.monitorID(
            focusedWorkspace: "6",
            activeWorkspaceByMonitor: [msi: "2", hdmi: "6"],
            fallbackMonitorID: msi
        )

        #expect(selected == hdmi)
    }

    @Test("the focus ring falls back when focused workspace is not active on any display")
    func borderUsesFallbackForInactiveWorkspace() {
        let msi: CGDirectDisplayID = 2
        let selected = FocusBorderPolicy.monitorID(
            focusedWorkspace: "2",
            activeWorkspaceByMonitor: [msi: "5"],
            fallbackMonitorID: msi
        )

        #expect(selected == msi)
    }

    @Test("the focus ring follows the focused window when the workspace is active on multiple displays")
    func focusedWindowDisplayWinsWhenWorkspaceIsShared() {
        let upper: CGDirectDisplayID = 2
        let lower: CGDirectDisplayID = 3
        let selected = FocusBorderPolicy.monitorID(
            focusedWorkspace: "2",
            activeWorkspaceByMonitor: [upper: "2", lower: "2"],
            focusedWindowMonitorID: lower,
            fallbackMonitorID: upper
        )

        #expect(selected == lower)
    }

    @Test("the focus ring uses the live window frame after it moves to another display")
    func liveWindowFrameWinsOverStaleCachedFrame() {
        let msi: CGDirectDisplayID = 2
        let hdmi: CGDirectDisplayID = 3
        let monitors = [
            MonitorInfo(id: msi, frame: Rect(x: 0, y: 0, width: 3_440, height: 1_440),
                        visibleFrame: Rect(x: 0, y: 0, width: 3_440, height: 1_410), name: "MSI"),
            MonitorInfo(id: hdmi, frame: Rect(x: 774, y: -1_080, width: 1_920, height: 1_080),
                        visibleFrame: Rect(x: 774, y: -1_080, width: 1_920, height: 1_080), name: "HDMI"),
        ]
        let staleMSIFrame = Rect(x: 800, y: 100, width: 1_000, height: 800)
        let liveHDMIFrame = Rect(x: 900, y: -1_000, width: 1_000, height: 800)

        #expect(FocusBorderPolicy.windowMonitorID(
            liveFrame: liveHDMIFrame,
            cachedFrame: staleMSIFrame,
            monitors: monitors
        ) == hdmi)
    }
}
