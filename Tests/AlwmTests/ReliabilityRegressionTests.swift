import AppKit
import Foundation
import Testing
@testable import Alwm

@Suite("Reliability regressions")
struct ReliabilityRegressionTests {
    @Test("overlay capture keeps the local toggle keyboard monitor installed")
    @MainActor
    func overlayCaptureKeepsToggleMonitor() {
        let hotkeys = HotkeyManager()
        hotkeys.installNSMonitorIfNeeded()
        defer { hotkeys.unregisterAll() }
        #expect(hotkeys.hasLocalMonitor)
        hotkeys.setOverlayKeyboardCapture(true)
        let installed = hotkeys.hasLocalMonitor
        #expect(installed)
    }

    @MainActor
    private func manager(root: URL) -> WindowManager {
        WindowManager(runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")), notesStore: NotesStore(root: root.appendingPathComponent("notes")))
    }

    @Test("a new window cannot inherit a stale same-title layout outside recovery")
    @MainActor
    func newWindowUsesActiveWorkspace() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(root: root)
        manager.isBootstrapping = false
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1"), .init(id: "2", name: "2")], monitors: [monitor])
        manager.workspaces.switchWorkspace(id: "2", on: monitor.id, monitors: [monitor])
        let id = WindowID(pid: 42, windowNumber: 100)
        let window = ManagedWindow(id: id, title: "Editor", bundleID: "example.editor", appName: "Editor", frame: monitor.visibleFrame)
        manager.windowsByID[id] = window
        manager.runtimeState.setBundleAssignment("1", for: window.bundleID)
        manager.runtimeState.setWorkspaceLayout(.init(columns: [.init(windows: [.init(token: "42:1", bundleID: window.bundleID, appName: window.appName, title: window.title)], width: 800)]), for: "1")
        #expect(manager.resolveTargetWorkspace(for: window, on: monitor) == "2")
    }

    @Test("a persistent Quake panel does not disable tile hotkeys after focus moves away")
    @MainActor
    func persistentQuakeReleasesKeyboard() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(root: root)
        var config = manager.configStore.config
        config.settings.quake.dismissOnClickOutside = false
        manager.configStore.replaceConfig(config)
        manager.quake.rebind(WindowID(pid: 999_999, windowNumber: 1))
        manager.quake.setVisibleForRecovery(true)
        manager.axFocusedWindowID = WindowID(pid: 888_888, windowNumber: 2)
        let captured = manager.overlaysCaptureFocus
        #expect(!captured)
    }

    @Test("an unsuccessful AX close cannot discard a live window and its layout")
    @MainActor
    func rejectedClosePreservesLayout() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(root: root)
        let id = WindowID(pid: 999_999, windowNumber: 3)
        manager.windowsByID[id] = ManagedWindow(
            id: id, title: "Unsaved", bundleID: "example.editor", appName: "Editor",
            frame: Rect(x: 0, y: 0, width: 800, height: 600)
        )
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1")], monitors: [])
        manager.workspaces.setWorkspace(WorkspaceState(id: "1", name: "1", columns: [.init(windows: [id], width: 800)]))
        manager.windowWorkspace[id] = "1"
        manager.closeWindow(id)
        #expect(manager.windowsByID[id] != nil)
        #expect(manager.workspaces.workspaceID(containing: id) == "1")
        #expect(manager.windowWorkspace[id] == "1")
    }

    @Test("popup detection includes normal-layer untracked app panels")
    @MainActor
    func detectsNormalLayerPopup() {
        let main: [String: Any] = [
            kCGWindowOwnerPID as String: 42, kCGWindowNumber as String: 1,
            kCGWindowLayer as String: 0,
            kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 1000, "Height": 800],
        ]
        let popup: [String: Any] = [
            kCGWindowOwnerPID as String: 42, kCGWindowNumber as String: 2,
            kCGWindowLayer as String: 0,
            kCGWindowBounds as String: ["X": 500, "Y": 100, "Width": 300, "Height": 400],
        ]
        #expect(AlwmChromeFocus.processHasPopupWindow(pid: 42, infos: [popup, main], managedWindowNumbers: [1]))
        #expect(!AlwmChromeFocus.processHasPopupWindow(pid: 42, infos: [main], managedWindowNumbers: [1]))
    }

    @Test("a closed-popup cache cannot mask a popup opened before the next mouse focus interval")
    @MainActor
    func staleNegativePopupCacheCannotStealFocus() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(root: root)
        manager.appPopupOpenCache = (Date().addingTimeInterval(-0.08), 42, false)
        let popup: [String: Any] = [
            kCGWindowOwnerPID as String: 42, kCGWindowNumber as String: 2,
            kCGWindowLayer as String: 0,
            kCGWindowBounds as String: ["X": 500, "Y": 100, "Width": 300, "Height": 400],
        ]
        let blocksFocus = manager.focusedAppHasTransientPopupOpen(pid: 42) {
            AlwmChromeFocus.processHasPopupWindow(pid: 42, infos: [popup], managedWindowNumbers: [1])
        }
        #expect(blocksFocus)
    }

    @Test("wake recovery cannot finish with changed stack heights or scroll position")
    @MainActor
    func recoveryChecksStackGeometry() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(root: root)
        let first = WindowID(pid: 42, windowNumber: 1)
        let second = WindowID(pid: 42, windowNumber: 2)
        for id in [first, second] {
            manager.windowsByID[id] = ManagedWindow(id: id, title: id.token, bundleID: "example.app", appName: "App", frame: Rect(x: 0, y: 0, width: 800, height: 600))
        }
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1")], monitors: [])
        manager.runtimeState.setWorkspaceLayout(.init(
            columns: [.init(windows: [first, second].map { .init(window: manager.windowsByID[$0]!) }, width: 800)],
            viewOffset: 140, leafWeights: [first.token: 0.3, second.token: 0.7]
        ), for: "1")
        manager.workspaces.setWorkspace(WorkspaceState(id: "1", name: "1", columns: [.init(windows: [first, second], width: 800)]))
        let matches = manager.layoutContentMatchesDiskSnapshot()
        #expect(!matches)
    }

    @Test("window-number churn must retain saved stack weights until rematching")
    func pruningPreservesRecoverableWeights() {
        let store = RuntimeStateStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.setWorkspaceLayout(.init(
            columns: [.init(windows: [.init(token: "42:1", bundleID: "example.app"), .init(token: "42:2", bundleID: "example.app")], width: 800)],
            leafWeights: ["42:1": 0.3, "42:2": 0.7]
        ), for: "1")
        store.pruneWindows(keeping: [WindowID(pid: 42, windowNumber: 100)])
        #expect(store.workspaceLayout(for: "1")?.leafWeights == ["42:1": 0.3, "42:2": 0.7])
    }

    @Test("a failed runtime reload retains the last usable recovery snapshot")
    func failedReloadPreservesState() {
        let store = RuntimeStateStore(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        store.setAssignment("2", for: WindowID(pid: 42, windowNumber: 1))
        store.load()
        #expect(store.assignment(for: WindowID(pid: 42, windowNumber: 1)) == "2")
    }

    @Test("editing two notes within the debounce interval saves both pages")
    @MainActor
    func savesAllEditedNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-notes-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(root: root)
        var first = store.createPage(title: "First")
        var second = store.createPage(title: "Second")
        first.title = "First edited"
        second.title = "Second edited"
        store.updatePage(first)
        store.updatePage(second)
        try await Task.sleep(for: .milliseconds(650))
        let reopened = NotesStore(root: root)
        #expect(reopened.page(first.id)?.title == "First edited")
        #expect(reopened.page(second.id)?.title == "Second edited")
    }

    @Test("deleting a note with a pending save cannot resurrect its page file")
    @MainActor
    func pendingSaveCannotResurrectDeletedNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-notes-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(root: root)
        var page = store.createPage()
        page.title = "Edited then deleted"
        store.updatePage(page)
        store.deletePage(page.id)
        try await Task.sleep(for: .milliseconds(650))
        let pageURL = root.appendingPathComponent("pages/\(page.id.uuidString).json")
        #expect(!FileManager.default.fileExists(atPath: pageURL.path))
    }

    @Test("a damaged notes index cannot overwrite existing page data")
    @MainActor
    func corruptedNotesIndexPreservesPages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-notes-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotesStore(root: root)
        let page = store.createPage(title: "Recoverable")
        try Data("damaged index".utf8).write(to: root.appendingPathComponent("index.json"), options: .atomic)
        let recovered = NotesStore(root: root)
        #expect(recovered.index.pages.contains { $0.id == page.id })
        #expect(recovered.page(page.id)?.title == "Recoverable")
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("index.corrupt-") }
        #expect(backups.count == 1)
    }

    @Test("mouse bursts share one pending focus check instead of cancelling and reallocating it")
    @MainActor
    func mouseFocusWorkIsCoalesced() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(root: root)
        manager.ffmLastRun = Date()
        let pending = DispatchWorkItem {}
        manager.ffmWorkItem = pending
        defer { manager.ffmWorkItem?.cancel() }
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 { manager.scheduleFocusWindowUnderMouse() }
        let coalesced = manager.ffmWorkItem === pending
        #expect(coalesced)
        print("ALWM focus scheduling 100 events: \(ProcessInfo.processInfo.systemUptime - started)s")
    }

    @Test("the display preparation step cannot renormalize a restored scrolling layout during wake")
    @MainActor
    func resumeDisplayPreparationPreservesOverflow() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        let manager = WindowManager(runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")), notesStore: NotesStore(root: root.appendingPathComponent("notes")), monitors: MonitorStore(monitors: [monitor]))
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1")], monitors: [monitor])
        let ids = [WindowID(pid: 42, windowNumber: 1), WindowID(pid: 42, windowNumber: 2)]
        for id in ids {
            manager.windowsByID[id] = ManagedWindow(id: id, title: id.token, bundleID: "example.app", appName: "App", frame: monitor.visibleFrame)
            manager.runtimeState.setAssignment("1", for: id)
        }
        manager.runtimeState.setWorkspaceLayout(.init(columns: ids.map { .init(windows: [.init(window: manager.windowsByID[$0]!)], width: 900) }, viewOffset: 200), for: "1")
        manager.isResumeRecovering = true
        manager.restoreWorkspaceLayout(for: "1")
        manager.prepareAllActiveWorkspaceLayouts()
        let restored = manager.workspaces.workspaces["1"]!
        #expect(restored.columns.map(\.width) == [900, 900])
        #expect(restored.viewOffset == 200)
    }

    @Test("wake verification uses stable logical display slots after screen enumeration reverses")
    @MainActor
    func resumeChecksLogicalMonitorSlots() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let builtIn = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Built-in")
        let external = MonitorInfo(id: 2, frame: .init(x: 1440, y: 0, width: 1920, height: 1080), visibleFrame: .init(x: 1440, y: 24, width: 1920, height: 1056), name: "External")
        let screens = [external, builtIn]
        let manager = WindowManager(runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")), notesStore: NotesStore(root: root.appendingPathComponent("notes")), monitors: MonitorStore(monitors: screens))
        manager.runtimeState.setLastWorkspace("3", on: builtIn.id)
        manager.runtimeState.setLastWorkspace("5", on: external.id)
        manager.workspaces.configure(definitions: [
            .init(id: "1", name: "1", monitorIndex: 0), .init(id: "3", name: "3", monitorIndex: 0),
            .init(id: "4", name: "4", monitorIndex: 1), .init(id: "5", name: "5", monitorIndex: 1),
        ], monitors: screens, savedWorkspaceByMonitor: [1: "3", 2: "5"], savedMonitorIndexByID: [1: 0, 2: 1])
        let matches = manager.persistedWorkspaceSelectionMatchesCurrent()
        #expect(matches)
    }

    @Test("sleep preparation flushes edits that have not reached their debounce deadline")
    @MainActor
    func sleepFlushesPendingNotes() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        let manager = manager(root: root)
        defer {
            manager.notepad.store.flushPendingSaves()
            manager.cancelPendingResumeRecovery()
            try? FileManager.default.removeItem(at: root)
        }
        var page = manager.notepad.store.createPage(title: "Before")
        page.title = "Saved before sleep"
        manager.notepad.store.updatePage(page)
        manager.prepareForSystemSleep()
        let reopened = NotesStore(root: root.appendingPathComponent("notes"))
        #expect(reopened.page(page.id)?.title == "Saved before sleep")
    }
}
