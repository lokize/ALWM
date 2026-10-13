import AppKit
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

    @Test("separate plugin badges create independent capsules and invalidate the render")
    @MainActor
    func separatePluginBadges() {
        let controller = WorkspaceBarController()
        let monitor = MonitorInfo(
            id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: .init(x: 0, y: 0, width: 1440, height: 878), name: "Display"
        )
        var settings = WorkspaceBarSettings.default
        let normal = controller.renderSignature(
            monitors: [monitor], definitions: [], activeByMonitor: [:], workspaces: [:],
            windowsByID: [:], windowWorkspace: [:], settings: settings, avoidRect: nil,
            pluginItems: [], focusedStatusLabel: ""
        )
        settings.separatePluginBadges = true
        let separate = controller.renderSignature(
            monitors: [monitor], definitions: [], activeByMonitor: [:], workspaces: [:],
            windowsByID: [:], windowWorkspace: [:], settings: settings, avoidRect: nil,
            pluginItems: [], focusedStatusLabel: ""
        )
        #expect(normal != separate)
        let first = controller.makePluginBadge(NSButton(title: "A", target: nil, action: nil), height: 20, alpha: 0.5, scale: 1)
        let second = controller.makePluginBadge(NSButton(title: "B", target: nil, action: nil), height: 20, alpha: 0.5, scale: 1)
        #expect(first !== second)
        #expect(first.subviews.count == second.subviews.count)
        #expect(first.subviews.contains { $0 is NSButton })
        #expect(second.subviews.contains { $0 is NSButton })
    }
}
