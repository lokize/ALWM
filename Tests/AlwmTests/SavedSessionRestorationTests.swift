import AppKit
import Foundation
import Testing
@testable import Alwm

@Suite("Saved session restoration")
struct SavedSessionRestorationTests {
    private func ref(_ token: String, _ bundle: String) -> RuntimeStateStore.WindowRef {
        .init(token: token, bundleID: bundle, appName: bundle, title: bundle)
    }

    @Test("startup launches each missing app with a saved window only once")
    func launchesOnlyMissingSavedApps() {
        let snapshot = RuntimeStateStore.Snapshot(
            bundleWorkspace: ["example.closed": "1"],
            workspaceLayouts: [
                "1": .init(columns: [.init(windows: [ref("1:1", "example.editor"), ref("1:2", "example.editor")])]),
                "2": .init(floating: [ref("2:1", "example.floating"), ref("3:1", "example.running")]),
            ]
        )
        #expect(SavedSessionRestorePolicy.bundleIDsToLaunch(
            snapshot: snapshot, runningBundleIDs: ["example.running"]
        ) == ["example.editor", "example.floating"])
    }

    @Test("startup reveals saved apps whose minimized windows were not discovered yet")
    func findsRunningSavedAppsMissingFromTheWindowScan() {
        let snapshot = RuntimeStateStore.Snapshot(workspaceLayouts: [
            "1": .init(columns: [.init(windows: [ref("1:1", "example.minimized")])]),
            "2": .init(floating: [ref("2:1", "example.visible")])
        ])

        #expect(SavedSessionRestorePolicy.bundleIDsToRevealMinimizedWindows(
            snapshot: snapshot,
            runningBundleIDs: ["example.minimized", "example.visible"],
            trackedBundleIDs: ["example.visible"]
        ) == ["example.minimized"])
    }

    @Test("the manager launches missing saved apps through its startup path")
    @MainActor
    func managerLaunchesSavedApps() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-session-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = WindowManager(
            runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")),
            notesStore: NotesStore(root: root.appendingPathComponent("notes"))
        )
        manager.runtimeState.setWorkspaceLayout(.init(columns: [
            .init(windows: [ref("1:1", "example.missing"), ref("1:2", "example.running")])
        ]), for: "1")
        var launched: [String] = []
        manager.restoreSavedSessionApps(runningBundleIDs: ["example.running"]) { launched.append($0) }
        #expect(launched == ["example.missing"])
    }

    @Test("closing the last window removes its saved slot so a later opening follows its rule")
    @MainActor
    func closedAppUsesConfiguredRuleOnReopen() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-session-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        let manager = WindowManager(
            runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")),
            notesStore: NotesStore(root: root.appendingPathComponent("notes")),
            monitors: MonitorStore(monitors: [monitor])
        )
        manager.isBootstrapping = false
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1"), .init(id: "2", name: "2")], monitors: [monitor])
        manager.workspaces.switchWorkspace(id: "1", on: monitor.id, monitors: [monitor])
        var config = manager.configStore.config
        config.rules = [AppRule(bundleID: "example.editor", workspace: "2")]
        manager.configStore.replaceConfig(config)
        let oldID = WindowID(pid: 999_801, windowNumber: 1)
        let old = ManagedWindow(id: oldID, title: "Editor", bundleID: "example.editor", appName: "Editor", frame: monitor.visibleFrame)
        manager.windowsByID[oldID] = old
        manager.windowWorkspace[oldID] = "1"
        manager.workspaces.setWorkspace(WorkspaceState(id: "1", name: "1", columns: [.init(windows: [oldID], width: 800)]))
        manager.runtimeState.setWorkspaceLayout(.init(columns: [.init(windows: [.init(window: old)], width: 800)]), for: "1")

        manager.handleUserClosedWindow(oldID)
        #expect(manager.runtimeState.workspaceLayout(for: "1")?.columns.flatMap(\.windows).isEmpty == true)

        let reopenedID = WindowID(pid: 999_802, windowNumber: 1)
        let reopened = ManagedWindow(id: reopenedID, title: "Editor", bundleID: "example.editor", appName: "Editor", frame: monitor.visibleFrame)
        manager.windowsByID[reopenedID] = reopened
        manager.resumeRecoveryEligibleUntil = Date().addingTimeInterval(20)
        #expect(manager.resolveTargetWorkspace(for: reopened, on: monitor) == "2")
    }

    @Test("floating window position and size survive a runtime snapshot round trip")
    func floatingFrameRoundTrips() throws {
        let frame = Rect(x: 170, y: 95, width: 640, height: 480)
        let snapshot = RuntimeStateStore.Snapshot(workspaceLayouts: [
            "2": .init(floating: [.init(token: "42:1", bundleID: "example.float", frame: frame)])
        ])
        let decoded = try JSONDecoder().decode(RuntimeStateStore.Snapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.workspaceLayouts["2"]?.floating.first?.frame == frame)
    }

    @Test("restoring a floating window binds its saved workspace and frame after PID churn")
    @MainActor
    func restoredFloatUsesSavedGeometry() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-session-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        let manager = WindowManager(
            runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")),
            notesStore: NotesStore(root: root.appendingPathComponent("notes")),
            monitors: MonitorStore(monitors: [monitor])
        )
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1"), .init(id: "2", name: "2")], monitors: [monitor])
        manager.workspaces.switchWorkspace(id: "2", on: monitor.id, monitors: [monitor])
        let frame = Rect(x: 175, y: 90, width: 620, height: 470)
        let liveID = WindowID(pid: 999_811, windowNumber: 2)
        manager.windowsByID[liveID] = ManagedWindow(
            id: liveID, title: "Palette", bundleID: "example.float", appName: "Float",
            frame: .init(x: 20, y: 30, width: 400, height: 300), isFloating: true
        )
        manager.runtimeState.setWorkspaceLayout(.init(floating: [
            .init(token: "999810:1", bundleID: "example.float", appName: "Float", title: "Palette", frame: frame)
        ]), for: "2")
        manager.restoreWorkspaceLayout(for: "2")
        #expect(manager.windowWorkspace[liveID] == "2")
        #expect(manager.savedFrames[liveID] == frame)
        #expect(manager.floatFrameForActiveHome(
            id: liveID, home: "2", live: manager.windowsByID[liveID]!.frame, layoutMonitor: monitor
        ) == frame)
    }

    @Test("startup persistence keeps a missing floating app until it can reopen")
    @MainActor
    func missingFloatSurvivesBootstrapPersist() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-session-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = WindowManager(
            runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")),
            notesStore: NotesStore(root: root.appendingPathComponent("notes"))
        )
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1")], monitors: [])
        manager.runtimeState.setWorkspaceLayout(.init(floating: [
            .init(token: "42:1", bundleID: "example.float", appName: "Float", title: "Palette",
                  frame: .init(x: 100, y: 90, width: 600, height: 450))
        ]), for: "1")
        manager.isBootstrapping = false
        manager.persistRuntimeState()
        #expect(manager.runtimeState.workspaceLayout(for: "1")?.floating.map(\.token) == ["42:1"])
    }

    @Test("other live windows cannot overwrite a missing app's saved workspace")
    @MainActor
    func missingAppLayoutSurvivesEqualTileCount() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-session-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = WindowManager(
            runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")),
            notesStore: NotesStore(root: root.appendingPathComponent("notes"))
        )
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1"), .init(id: "2", name: "2")], monitors: [])
        manager.runtimeState.setWorkspaceLayout(.init(columns: [
            .init(windows: [.init(token: "42:1", bundleID: "example.missing", appName: "Missing", title: "Document")], width: 730)
        ]), for: "1")
        manager.runtimeState.setWorkspaceLayout(.init(columns: [
            .init(windows: [.init(token: "43:1", bundleID: "example.live", appName: "Live", title: "One")], width: 680)
        ]), for: "2")
        let liveIDs = [WindowID(pid: 43, windowNumber: 1), WindowID(pid: 43, windowNumber: 2)]
        for id in liveIDs {
            manager.windowsByID[id] = ManagedWindow(
                id: id, title: id.token, bundleID: "example.live", appName: "Live",
                frame: .init(x: 0, y: 0, width: 680, height: 600)
            )
            manager.windowWorkspace[id] = "2"
        }
        manager.workspaces.setWorkspace(WorkspaceState(id: "2", name: "2", columns: liveIDs.map { .init(windows: [$0], width: 680) }))
        manager.isBootstrapping = false
        manager.persistRuntimeState()
        #expect(manager.runtimeState.workspaceLayout(for: "1")?.columns.first?.windows.first?.bundleID == "example.missing")
    }

    @Test("a newly opened floating app uses its configured workspace")
    @MainActor
    func floatingRuleChoosesWorkspace() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-session-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        let manager = WindowManager(
            runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")),
            notesStore: NotesStore(root: root.appendingPathComponent("notes")),
            monitors: MonitorStore(monitors: [monitor])
        )
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1"), .init(id: "2", name: "2")], monitors: [monitor])
        manager.workspaces.switchWorkspace(id: "1", on: monitor.id, monitors: [monitor])
        var config = manager.configStore.config
        config.rules = [AppRule(bundleID: "example.float", mode: .float, workspace: "2")]
        manager.configStore.replaceConfig(config)
        let id = WindowID(pid: 999_821, windowNumber: 1)
        let win = ManagedWindow(id: id, title: "Palette", bundleID: "example.float", appName: "Float",
                                frame: .init(x: 60, y: 60, width: 400, height: 300), isFloating: true)
        manager.windowsByID[id] = win
        manager.ensureFloatHome(id, win: win)
        #expect(manager.windowWorkspace[id] == "2")
    }

    @Test("a confirmed missing AX window also leaves the saved session")
    @MainActor
    func confirmedMissingWindowRemovesSavedSlot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-session-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        let manager = WindowManager(
            runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")),
            notesStore: NotesStore(root: root.appendingPathComponent("notes")),
            monitors: MonitorStore(monitors: [monitor])
        )
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1")], monitors: [monitor])
        let id = WindowID(pid: 999_831, windowNumber: 1)
        let win = ManagedWindow(id: id, title: "Closed", bundleID: "example.closed", appName: "Closed", frame: monitor.visibleFrame)
        manager.windowsByID[id] = win
        manager.windowWorkspace[id] = "1"
        manager.workspaces.setWorkspace(WorkspaceState(id: "1", name: "1", columns: [.init(windows: [id], width: 800)]))
        manager.runtimeState.setWorkspaceLayout(.init(columns: [.init(windows: [.init(window: win)], width: 800)]), for: "1")
        manager.isBootstrapping = false
        manager.ingest(windows: [])
        try await Task.sleep(for: .milliseconds(800))
        manager.ingest(windows: [])
        #expect(manager.runtimeState.workspaceLayout(for: "1")?.columns.flatMap(\.windows).isEmpty == true)
    }

    @Test("a saved floating window stays floating when its app recreates a standard window")
    @MainActor
    func manuallyFloatingWindowRestoresAsFloat() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-session-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        let manager = WindowManager(
            runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")),
            notesStore: NotesStore(root: root.appendingPathComponent("notes")),
            monitors: MonitorStore(monitors: [monitor])
        )
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1")], monitors: [monitor])
        let id = WindowID(pid: 999_841, windowNumber: 2)
        manager.windowsByID[id] = ManagedWindow(
            id: id, title: "Utility", bundleID: "example.utility", appName: "Utility",
            frame: .init(x: 0, y: 0, width: 700, height: 500)
        )
        manager.runtimeState.setWorkspaceLayout(.init(floating: [
            .init(token: "999840:1", bundleID: "example.utility", appName: "Utility", title: "Utility",
                  frame: .init(x: 95, y: 75, width: 700, height: 500))
        ]), for: "1")
        manager.restoreWorkspaceLayout(for: "1")
        manager.retileAccidentalFloats(forceClearOverrides: true)
        #expect(manager.windowsByID[id]?.isFloating == true)
        #expect(manager.floatingOverrides.contains(id))
    }
}

@Suite("Move-to-workspace target selection")
struct MoveToWorkspaceTargetSelectionTests {
    @Test("the live frontmost window beats a stale cached focus")
    func liveFrontmostWindowWins() {
        let stale = WindowID(pid: 42, windowNumber: 100)
        let current = WindowID(pid: 43, windowNumber: 200)

        #expect(MoveToWorkspaceTargetPolicy.resolve(
            frontmost: current,
            cached: stale,
            workspaceFocused: stale,
            isActionable: { _ in true }
        ) == current)
    }

    @Test("an unmanaged popup is skipped in favor of the last actionable window")
    func unmanagedFrontmostFallsBackToActionableWindow() {
        let popup = WindowID(pid: 42, windowNumber: 300)
        let appWindow = WindowID(pid: 42, windowNumber: 100)

        #expect(MoveToWorkspaceTargetPolicy.resolve(
            frontmost: popup,
            cached: appWindow,
            workspaceFocused: nil,
            isActionable: { $0 == appWindow }
        ) == appWindow)
    }
}
