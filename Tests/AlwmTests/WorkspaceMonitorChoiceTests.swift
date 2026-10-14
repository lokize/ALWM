import Testing
@testable import Alwm

@Suite("Workspace monitor choices")
struct WorkspaceMonitorChoiceTests {
    @Test("settings use the same logical monitor slots as workspace layout")
    func settingsChoicesUseLogicalIndices() {
        let msi = MonitorInfo(
            id: 2,
            frame: Rect(x: 0, y: 0, width: 3440, height: 1440),
            visibleFrame: Rect(x: 0, y: 0, width: 3440, height: 1440),
            name: "MSI MAG401QR"
        )
        let hdmi = MonitorInfo(
            id: 3,
            frame: Rect(x: 774, y: 1440, width: 1920, height: 1080),
            visibleFrame: Rect(x: 774, y: 1440, width: 1920, height: 1080),
            name: "HDMI"
        )

        let choices = WorkspaceMonitorChoice.make(
            monitors: [msi, hdmi],
            indicesByID: [msi.id: 1, hdmi.id: 0]
        )

        #expect(choices.map { "\($0.monitor.id):\($0.index)" } == ["3:0", "2:1"])
    }
}
