import Testing
@testable import Alwm

@Suite("Workspace layout refresh")
struct WorkspaceLayoutRefreshTests {
    @Test("refresh keeps the live window order, widths, and scroll position")
    @MainActor
    func keepsLiveLayoutWhenSnapshotIsStale() {
        let manager = WindowManager()
        let first = WindowID(pid: 42, windowNumber: 1)
        let second = WindowID(pid: 42, windowNumber: 2)
        let firstWindow = ManagedWindow(
            id: first,
            title: "First",
            bundleID: "com.example.app",
            appName: "Example",
            frame: Rect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let secondWindow = ManagedWindow(
            id: second,
            title: "Second",
            bundleID: "com.example.app",
            appName: "Example",
            frame: Rect(x: 0, y: 0, width: 1_000, height: 800)
        )
        manager.windowsByID = [first: firstWindow, second: secondWindow]
        manager.windowWorkspace = [first: "1", second: "1"]
        manager.workspaces.configure(
            definitions: [WorkspaceDefinition(id: "1", name: "1", layout: .niri)],
            monitors: []
        )

        manager.workspaces.setWorkspace(WorkspaceState(
            id: "1",
            name: "1",
            columns: [Column(windows: [second], width: 820), Column(windows: [first], width: 510)],
            focusedColumn: 1,
            viewOffset: 73
        ))
        manager.runtimeState.setWorkspaceLayout(RuntimeStateStore.WorkspaceLayoutSnapshot(
            columns: [
                .init(windows: [RuntimeStateStore.WindowRef(window: firstWindow)], width: 1_000),
                .init(windows: [RuntimeStateStore.WindowRef(window: secondWindow)], width: 1_000),
            ],
            focusedColumn: 0,
            viewOffset: 0
        ), for: "1")

        manager.refreshWorkspaceLayoutFromSnapshot(for: "1")

        let refreshed = manager.workspaces.workspaces["1"]!
        #expect(refreshed.orderedWindowIDs == [second, first])
        #expect(refreshed.columns.map(\.width) == [820, 510])
        #expect(refreshed.focusedColumn == 1)
        #expect(refreshed.viewOffset == 73)
    }

    @Test("refresh restores a missing live tile in its saved column and size")
    @MainActor
    func restoresMissingTileFromSavedLayout() {
        let manager = WindowManager()
        let first = WindowID(pid: 43, windowNumber: 1)
        let second = WindowID(pid: 43, windowNumber: 2)
        let firstWindow = ManagedWindow(
            id: first,
            title: "First",
            bundleID: "com.example.app",
            appName: "Example",
            frame: Rect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let secondWindow = ManagedWindow(
            id: second,
            title: "Second",
            bundleID: "com.example.app",
            appName: "Example",
            frame: Rect(x: 0, y: 0, width: 1_000, height: 800)
        )
        manager.windowsByID = [first: firstWindow, second: secondWindow]
        manager.windowWorkspace = [first: "1", second: "1"]
        manager.workspaces.configure(
            definitions: [WorkspaceDefinition(id: "1", name: "1", layout: .niri)],
            monitors: []
        )
        manager.workspaces.setWorkspace(WorkspaceState(
            id: "1",
            name: "1",
            columns: [Column(windows: [first], width: 760)]
        ))
        manager.runtimeState.setWorkspaceLayout(RuntimeStateStore.WorkspaceLayoutSnapshot(
            columns: [
                .init(windows: [RuntimeStateStore.WindowRef(window: firstWindow)], width: 600),
                .init(windows: [RuntimeStateStore.WindowRef(window: secondWindow)], width: 440),
            ]
        ), for: "1")

        manager.refreshWorkspaceLayoutFromSnapshot(for: "1")

        let refreshed = manager.workspaces.workspaces["1"]!
        #expect(refreshed.orderedWindowIDs == [first, second])
        #expect(refreshed.columns.map(\.width) == [760, 440])
    }

    @Test("an empty in-memory workspace regains its saved scroll position")
    @MainActor
    func restoresSavedScrollPositionWhenWorkspaceWasEmptied() {
        let manager = WindowManager()
        let id = WindowID(pid: 45, windowNumber: 1)
        let window = ManagedWindow(
            id: id,
            title: "Editor",
            bundleID: "com.example.editor",
            appName: "Editor",
            frame: Rect(x: 0, y: 0, width: 1_000, height: 800)
        )
        manager.windowsByID[id] = window
        manager.windowWorkspace[id] = "1"
        manager.workspaces.configure(
            definitions: [WorkspaceDefinition(id: "1", name: "1", layout: .niri)],
            monitors: []
        )
        manager.runtimeState.setWorkspaceLayout(RuntimeStateStore.WorkspaceLayoutSnapshot(
            columns: [.init(windows: [RuntimeStateStore.WindowRef(window: window)], width: 720)],
            viewOffset: 160
        ), for: "1")

        manager.refreshWorkspaceLayoutFromSnapshot(for: "1")

        let refreshed = manager.workspaces.workspaces["1"]!
        #expect(refreshed.orderedWindowIDs == [id])
        #expect(refreshed.viewOffset == 160)
    }

    @Test("resume restores saved workspace order, column sizes, and scroll position")
    @MainActor
    func restoresSavedLayoutAfterResume() {
        let manager = WindowManager()
        let first = WindowID(pid: 44, windowNumber: 1)
        let second = WindowID(pid: 44, windowNumber: 2)
        let firstWindow = ManagedWindow(
            id: first,
            title: "First",
            bundleID: "com.example.app",
            appName: "Example",
            frame: Rect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let secondWindow = ManagedWindow(
            id: second,
            title: "Second",
            bundleID: "com.example.app",
            appName: "Example",
            frame: Rect(x: 0, y: 0, width: 1_000, height: 800)
        )
        manager.windowsByID = [first: firstWindow, second: secondWindow]
        manager.runtimeState.setAssignment("2", for: first)
        manager.runtimeState.setAssignment("2", for: second)
        manager.workspaces.configure(
            definitions: [WorkspaceDefinition(id: "2", name: "2", layout: .niri)],
            monitors: []
        )
        manager.runtimeState.setWorkspaceLayout(RuntimeStateStore.WorkspaceLayoutSnapshot(
            columns: [
                .init(windows: [RuntimeStateStore.WindowRef(window: secondWindow)], width: 780),
                .init(windows: [RuntimeStateStore.WindowRef(window: firstWindow)], width: 460),
            ],
            focusedColumn: 1,
            viewOffset: 125
        ), for: "2")
        manager.isResumeRecovering = true

        manager.restoreWorkspaceLayout(for: "2")

        let restored = manager.workspaces.workspaces["2"]!
        #expect(restored.orderedWindowIDs == [second, first])
        #expect(restored.columns.map(\.width) == [780, 460])
        #expect(restored.focusedColumn == 1)
        #expect(restored.viewOffset == 125)
    }
}
