import Foundation
import Testing
@testable import Alwm

@Suite("Workspace layout refresh")
struct WorkspaceLayoutRefreshTests {
    @Test("switching away and back preserves resized column widths and scroll offset")
    @MainActor
    func switchBackKeepsOversizedColumns() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-switch-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = MonitorInfo(
            id: 2,
            frame: Rect(x: 0, y: 0, width: 3_440, height: 1_440),
            visibleFrame: Rect(x: 0, y: 0, width: 3_440, height: 1_440),
            name: "MSI"
        )
        let manager = WindowManager(
            runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")),
            notesStore: NotesStore(root: root.appendingPathComponent("notes")),
            monitors: MonitorStore(monitors: [monitor])
        )
        manager.workspaces.configure(
            definitions: [WorkspaceDefinition(id: "1", name: "1"), WorkspaceDefinition(id: "2", name: "2")],
            monitors: [monitor]
        )
        let first = WindowID(pid: 999_901, windowNumber: 1)
        let second = WindowID(pid: 999_902, windowNumber: 2)
        manager.windowsByID[first] = ManagedWindow(
            id: first, title: "First", bundleID: "test.first", appName: "First",
            frame: Rect(x: 0, y: 0, width: 2_100, height: 1_000)
        )
        manager.windowsByID[second] = ManagedWindow(
            id: second, title: "Second", bundleID: "test.second", appName: "Second",
            frame: Rect(x: 2_100, y: 0, width: 1_700, height: 1_000)
        )
        manager.windowWorkspace = [first: "1", second: "1"]
        manager.workspaces.setWorkspace(WorkspaceState(
            id: "1", name: "1",
            columns: [Column(windows: [first], width: 2_100), Column(windows: [second], width: 1_700)],
            focusedColumn: 1,
            viewOffset: 420
        ))
        manager.isBootstrapping = false

        manager.switchWorkspace(id: "2", on: monitor.id)
        #expect(manager.workspaces.workspaces["1"]?.columns.map(\.width) == [2_100, 1_700])
        #expect(manager.workspaces.workspaces["1"]?.viewOffset == 420)
        manager.switchWorkspace(id: "1", on: monitor.id)

        let restored = manager.workspaces.workspaces["1"]!
        #expect(restored.columns.map(\.width) == [2_100, 1_700])
        #expect(restored.viewOffset == 420)
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(manager.workspaces.workspaces["1"]?.columns.map(\.width) == [2_100, 1_700])
        #expect(manager.workspaces.workspaces["1"]?.viewOffset == 420)
    }

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
