import CoreGraphics
import Testing
@testable import Alwm

@Suite("Focus follows mouse border routing")
struct FocusBorderPolicyTests {
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
}
