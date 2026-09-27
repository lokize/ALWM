import Testing
@testable import Alwm

@Suite("Workspace bar rendering")
struct WorkspaceBarRenderTests {
    @Test("render signature changes when monitor geometry changes")
    @MainActor
    func monitorGeometryInvalidatesRender() {
        let controller = WorkspaceBarController()
        let settings = WorkspaceBarSettings.default
        let first = MonitorInfo(
            id: 987_654,
            frame: Rect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: Rect(x: 0, y: 0, width: 1440, height: 878),
            name: "Display"
        )
        let resized = MonitorInfo(
            id: first.id,
            frame: Rect(x: 0, y: 0, width: 1680, height: 1050),
            visibleFrame: Rect(x: 0, y: 0, width: 1680, height: 1028),
            name: first.name
        )

        func signature(_ monitor: MonitorInfo) -> String {
            controller.renderSignature(
                monitors: [monitor],
                definitions: [],
                activeByMonitor: [:],
                workspaces: [:],
                windowsByID: [:],
                windowWorkspace: [:],
                settings: settings,
                avoidRect: nil,
                pluginItems: [],
                focusedStatusLabel: ""
            )
        }

        #expect(signature(first) != signature(resized))
    }
}
