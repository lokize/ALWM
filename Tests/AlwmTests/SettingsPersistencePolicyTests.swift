import Foundation
import Testing
@testable import Alwm

@Suite("Settings persistence")
struct SettingsPersistencePolicyTests {
    @Test("closing untouched settings does not write its stale initial snapshot")
    func doesNotFlushUntouchedSnapshot() {
        #expect(!SettingsPersistencePolicy.shouldFlushOnDisappear(hasPendingLocalChanges: false))
    }

    @Test("closing settings flushes a pending local edit")
    func flushesPendingEdit() {
        #expect(SettingsPersistencePolicy.shouldFlushOnDisappear(hasPendingLocalChanges: true))
    }

    @Test("coordinator does not flush or call onSave when untouched")
    @MainActor
    func coordinatorDoesNotFlushWhenUntouched() {
        var saved = false
        let coordinator = SettingsPersistCoordinator(config: .default, onSave: { _ in saved = true })
        coordinator.flushIfNeeded()
        #expect(!saved)
        #expect(!coordinator.hasPendingChanges)
    }

    @Test("coordinator flushes and calls onSave when changes are pending")
    @MainActor
    func coordinatorFlushesWhenPending() {
        var savedConfig: AlwmConfig?
        let coordinator = SettingsPersistCoordinator(config: .default, onSave: { c in savedConfig = c })
        var modified = AlwmConfig.default
        modified.settings.focusFollowsMouse = true
        coordinator.hasPendingChanges = true
        coordinator.liveConfig = modified
        coordinator.flushIfNeeded()
        #expect(savedConfig?.settings.focusFollowsMouse == true)
        #expect(!coordinator.hasPendingChanges)
    }

    @Test("reconcileWorkspacesWithRuntimeState recovers missing workspaces from runtime layouts")
    @MainActor
    func reconcileWorkspacesRecoversMissingWorkspaces() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-reconcile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStateStore(url: root.appendingPathComponent("runtime.json"))
        // Simulate runtime state having layouts for 5 and 6
        store.setWorkspaceLayout(
            .init(columns: [.init(windows: [.init(token: "100:1", bundleID: "com.apple.Safari", appName: "Safari", title: "YouTube")], width: 1920)]),
            for: "5"
        )
        store.setWorkspaceLayout(
            .init(columns: [.init(windows: [.init(token: "200:1", bundleID: "ru.keepcoder.Telegram", appName: "Telegram", title: "Telegram")], width: 1920)]),
            for: "6"
        )
        store.setLastWorkspace("5", on: 2)
        store.setMonitorIndex(1, for: 2)

        let manager = WindowManager(runtimeState: store, notesStore: NotesStore(root: root.appendingPathComponent("notes")))
        // config has only 1..4
        var config = AlwmConfig.default
        config.workspaces = [
            WorkspaceDefinition(id: "1", name: "1", layout: .niri, monitorIndex: 0),
            WorkspaceDefinition(id: "2", name: "2", layout: .niri, monitorIndex: 0),
            WorkspaceDefinition(id: "3", name: "3", layout: .dwindle, monitorIndex: 0),
            WorkspaceDefinition(id: "4", name: "4", layout: .niri, monitorIndex: 1),
        ]
        manager.configStore.replaceConfig(config)
        manager.reconcileWorkspacesWithRuntimeState()

        let recovered = manager.configStore.config.workspaces
        #expect(recovered.contains { $0.id == "5" && $0.monitorIndex == 1 })
        #expect(recovered.contains { $0.id == "6" && $0.monitorIndex == 1 })
        // Workspace 4 should have been moved to monitor 0 since 5 & 6 are on monitor 1
        #expect(recovered.first { $0.id == "4" }?.monitorIndex == 0)
    }
}
