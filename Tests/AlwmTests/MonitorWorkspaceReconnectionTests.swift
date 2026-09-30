import CoreGraphics
import Testing
@testable import Alwm

@Suite("Monitor workspace reconnection")
struct MonitorWorkspaceReconnectionTests {
    @Test("the sole remaining display can show workspaces pinned to a disconnected display")
    func keepsPinnedWorkspaceAccessibleInClamshell() {
        let builtIn = MonitorInfo(
            id: 101,
            frame: Rect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: Rect(x: 0, y: 24, width: 1440, height: 876),
            name: "Built-in"
        )
        let external = MonitorInfo(
            id: 202,
            frame: Rect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: Rect(x: 1440, y: 24, width: 1920, height: 1056),
            name: "External"
        )
        let definitions = [
            WorkspaceDefinition(id: "1", name: "1", layout: .niri, monitorIndex: 0),
            WorkspaceDefinition(id: "4", name: "4", layout: .niri, monitorIndex: 1),
            WorkspaceDefinition(id: "5", name: "5", layout: .niri, monitorIndex: 1),
        ]
        let store = WorkspaceStore()

        store.configure(definitions: definitions, monitors: [builtIn, external])
        store.switchWorkspace(id: "5", on: external.id, monitors: [builtIn, external])
        store.configure(definitions: definitions, monitors: [external])

        #expect(store.activeWorkspaceByMonitor[external.id] == "5")
        #expect(store.definitionsVisible(onMonitorIndex: 0).map(\.id) == ["1", "4", "5"])
        #expect(WorkspaceStore.definitions(
            definitions,
            visibleOnMonitorIndex: 0,
            connectedMonitorCount: 1
        ).map(\.id) == ["1", "4", "5"])
        #expect(store.preferredMonitor(forWorkspace: "5", monitors: [external])?.id == external.id)
        store.switchWorkspace(id: "1", on: external.id, monitors: [external])
        #expect(store.activeWorkspaceByMonitor[external.id] == "1")
        store.switchWorkspace(id: "5", on: external.id, monitors: [external])
        store.configure(definitions: definitions, monitors: [builtIn, external])
        #expect(store.activeWorkspaceByMonitor[external.id] == "5")
        #expect(store.activeWorkspaceByMonitor[builtIn.id] == "1")
    }

    @Test("reconnecting a display restores its active workspace")
    func keepsWorkspaceAcrossTemporaryDisconnect() {
        let builtIn = MonitorInfo(
            id: 101,
            frame: Rect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: Rect(x: 0, y: 24, width: 1440, height: 876),
            name: "Built-in"
        )
        let external = MonitorInfo(
            id: 202,
            frame: Rect(x: 1440, y: 0, width: 1920, height: 1080),
            visibleFrame: Rect(x: 1440, y: 24, width: 1920, height: 1056),
            name: "External"
        )
        let definitions = [
            WorkspaceDefinition(id: "1", name: "1", layout: .niri, monitorIndex: 0),
            WorkspaceDefinition(id: "4", name: "4", layout: .niri, monitorIndex: 1),
            WorkspaceDefinition(id: "5", name: "5", layout: .niri, monitorIndex: 1),
        ]
        let store = WorkspaceStore()

        store.configure(definitions: definitions, monitors: [builtIn, external])
        store.switchWorkspace(id: "5", on: external.id, monitors: [builtIn, external])
        store.configure(definitions: definitions, monitors: [builtIn])
        #expect(store.activeWorkspaceByMonitor[external.id] == nil)

        store.configure(definitions: definitions, monitors: [builtIn, external])
        #expect(store.activeWorkspaceByMonitor[external.id] == "5")
    }
}
