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

    @Test("a newly opened app with a saved same-title window joins the active workspace")
    @MainActor
    func newWindowWithSavedTitleUsesActiveWorkspace() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        let manager = WindowManager(
            runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")),
            notesStore: NotesStore(root: root.appendingPathComponent("notes")),
            monitors: MonitorStore(monitors: [monitor])
        )
        manager.isBootstrapping = false
        manager.resumeRecoveryEligibleUntil = Date().addingTimeInterval(5)
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1"), .init(id: "2", name: "2")], monitors: [monitor])
        manager.workspaces.switchWorkspace(id: "2", on: monitor.id, monitors: [monitor])
        manager.runtimeState.setWorkspaceLayout(.init(columns: [.init(windows: [
            .init(token: "41:10", bundleID: "com.philandro.anydesk", appName: "AnyDesk", title: "Nova sessão")
        ], width: 800)]), for: "1")

        let window = ManagedWindow(
            id: WindowID(pid: 42, windowNumber: 11), title: "Nova sessão",
            bundleID: "com.philandro.anydesk", appName: "AnyDesk", frame: monitor.visibleFrame
        )

        manager.windowsByID[window.id] = window
        #expect(manager.diskLayoutClaimsWindow(window.id, allowFuzzy: true))
        #expect(manager.savedHome(for: window, id: window.id) == "1")
        #expect(manager.initialWorkspaceForNewWindow(for: window, on: monitor) == "2")
    }

    @Test("new windows use the active workspace of the current monitor, not their default frame monitor")
    @MainActor
    func newWindowUsesCurrentMonitorWorkspace() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let left = MonitorInfo(id: 2, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Left")
        let right = MonitorInfo(id: 3, frame: .init(x: 1440, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 1440, y: 24, width: 1440, height: 876), name: "Right")
        let manager = WindowManager(
            runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")),
            notesStore: NotesStore(root: root.appendingPathComponent("notes")),
            monitors: MonitorStore(monitors: [left, right])
        )
        manager.isBootstrapping = false
        manager.primaryMonitorID = right.id
        manager.workspaces.configure(definitions: [
            .init(id: "1", name: "1", monitorIndex: 0),
            .init(id: "5", name: "5", monitorIndex: 1),
        ], monitors: [left, right])
        manager.workspaces.switchWorkspace(id: "1", on: left.id, monitors: [left, right])
        manager.workspaces.switchWorkspace(id: "5", on: right.id, monitors: [left, right])
        let window = ManagedWindow(
            id: WindowID(pid: 42, windowNumber: 101), title: "UTM",
            bundleID: "com.utmapp.UTM", appName: "UTM",
            frame: .init(x: 100, y: 100, width: 900, height: 700)
        )

        #expect(manager.initialWorkspaceForNewWindow(for: window, on: left) == "5")
        var config = manager.configStore.config
        config.rules.append(AppRule(bundleID: "com.utmapp.UTM", workspace: "1"))
        manager.configStore.replaceConfig(config)
        #expect(manager.initialWorkspaceForNewWindow(for: window, on: left) == "1")
    }

    @Test("a reused window token does not override an app rule on another monitor")
    @MainActor
    func reusedTokenUsesAppRuleWorkspace() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let msi = MonitorInfo(id: 2, frame: .init(x: 0, y: 0, width: 3440, height: 1440), visibleFrame: .init(x: 0, y: 0, width: 3440, height: 1440), name: "MSI")
        let hdmi = MonitorInfo(id: 3, frame: .init(x: 3440, y: 0, width: 1920, height: 1080), visibleFrame: .init(x: 3440, y: 0, width: 1920, height: 1080), name: "HDMI")
        let manager = WindowManager(
            runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")),
            notesStore: NotesStore(root: root.appendingPathComponent("notes")),
            monitors: MonitorStore(monitors: [msi, hdmi])
        )
        manager.isBootstrapping = false
        manager.workspaces.configure(definitions: [
            .init(id: "2", name: "2", monitorIndex: 0),
            .init(id: "5", name: "5", monitorIndex: 1),
        ], monitors: [msi, hdmi])
        manager.workspaces.switchWorkspace(id: "2", on: msi.id, monitors: [msi, hdmi])
        manager.workspaces.switchWorkspace(id: "5", on: hdmi.id, monitors: [msi, hdmi])
        var config = manager.configStore.config
        config.rules.append(AppRule(bundleID: "net.whatsapp.WhatsApp", workspace: "5"))
        manager.configStore.replaceConfig(config)

        let id = WindowID(pid: 1087, windowNumber: 109)
        manager.runtimeState.setAssignment("2", for: id) // stale assignment; no saved layout slot
        let window = ManagedWindow(
            id: id,
            title: "WhatsApp",
            bundleID: "net.whatsapp.WhatsApp",
            appName: "WhatsApp",
            frame: .init(x: 3500, y: 40, width: 1200, height: 900)
        )

        manager.ingest(windows: [window])

        #expect(manager.workspaces.workspaceID(containing: id) == "5")
        #expect(manager.windowWorkspace[id] == "5")
    }

    @Test("assigning a window to its current home removes copies on other workspaces")
    @MainActor
    func assignmentHealsDuplicateWorkspaceMembership() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let msi = MonitorInfo(id: 2, frame: .init(x: 0, y: 0, width: 3440, height: 1440), visibleFrame: .init(x: 0, y: 0, width: 3440, height: 1440), name: "MSI")
        let hdmi = MonitorInfo(id: 3, frame: .init(x: 3440, y: 0, width: 1920, height: 1080), visibleFrame: .init(x: 3440, y: 0, width: 1920, height: 1080), name: "HDMI")
        let manager = WindowManager(
            runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")),
            notesStore: NotesStore(root: root.appendingPathComponent("notes")),
            monitors: MonitorStore(monitors: [msi, hdmi])
        )
        manager.workspaces.configure(definitions: [
            .init(id: "2", name: "2", monitorIndex: 0),
            .init(id: "5", name: "5", monitorIndex: 1),
        ], monitors: [msi, hdmi])

        let id = WindowID(pid: 42614, windowNumber: 666)
        let window = ManagedWindow(
            id: id,
            title: "Restored Editor",
            bundleID: "example.editor",
            appName: "Editor",
            frame: .init(x: 3500, y: 40, width: 1200, height: 900)
        )
        manager.windowsByID[id] = window
        manager.workspaces.setWorkspace(WorkspaceState(id: "2", name: "2", columns: [.init(windows: [id], width: 1600)]))
        manager.workspaces.setWorkspace(WorkspaceState(id: "5", name: "5", columns: [.init(windows: [id], width: 900)]))
        // Resolve whichever copy WorkspaceStore currently treats as authoritative,
        // then ask the normal assignment path to retain that home.
        let home = manager.workspaces.workspaceID(containing: id)!
        manager.windowWorkspace[id] = home
        manager.runtimeState.setAssignment(home, for: id)
        let monitor = home == "2" ? msi : hdmi

        manager.assignWindow(id, to: home, on: monitor)

        let memberships = manager.workspaces.workspaces.values
            .flatMap(\.columns)
            .flatMap(\.windows)
            .filter { $0 == id }
        #expect(memberships == [id])
    }

    @Test("a visible Quake panel keeps overlay focus after macOS reports another window")
    @MainActor
    func visibleQuakeRetainsOverlayFocus() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(root: root)
        var config = manager.configStore.config
        config.settings.quake.dismissOnClickOutside = true
        manager.configStore.replaceConfig(config)
        manager.quake.rebind(WindowID(pid: 999_999, windowNumber: 1))
        manager.quake.setVisibleForRecovery(true)
        manager.axFocusedWindowID = WindowID(pid: 888_888, windowNumber: 2)
        let captured = manager.overlaysCaptureFocus
        #expect(captured)
    }

    @Test("an outside click is intercepted before it can select the window underneath")
    func outsideOverlayClickIsConsumed() {
        let overlay = Rect(x: 100, y: 100, width: 500, height: 300)
        #expect(OverlayClickCapturePolicy.shouldConsumeOutsideClick(
            pointX: 700, pointY: 700, visibleFrames: [overlay]
        ))
        #expect(!OverlayClickCapturePolicy.shouldConsumeOutsideClick(
            pointX: 200, pointY: 200, visibleFrames: [overlay]
        ))
        #expect(OverlayClickCapturePolicy.shouldConsumeOutsideClick(
            pointX: 700, pointY: 700, visibleFrames: [overlay]
        ))
        #expect(!OverlayClickCapturePolicy.shouldConsumeOutsideClick(
            pointX: 700, pointY: 700, visibleFrames: []
        ))
    }

    @Test("click outside a low overlay is not mirrored into its visible frame")
    func lowOverlayOutsideClickUsesAXCoordinateOrigin() {
        let lowOverlay = Rect(x: 100, y: 700, width: 500, height: 150)
        #expect(OverlayClickCapturePolicy.shouldConsumeEventOutsideClick(
            x: 500,
            y: 150,
            visibleFrames: [lowOverlay]
        ))
    }

    @Test("fullscreen toggle uses the display bounds and restores the exact prior geometry")
    func fullscreenToggleRestoresFrame() {
        let windowed = Rect(x: 140, y: 90, width: 760, height: 510)
        let screen = Rect(x: 0, y: 0, width: 1440, height: 900)
        var state = OverlayFullscreenState()
        #expect(state.toggle(currentFrame: windowed, displayFrame: screen) == screen)
        #expect(state.isFullscreen)
        #expect(state.toggle(currentFrame: screen, displayFrame: screen) == windowed)
        #expect(!state.isFullscreen)
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

    @Test("an unmanaged app popup blocks focus only when it is the top window under the pointer")
    func popupHitPreventsFocusingWindowBehindIt() {
        #expect(FocusFollowsMousePolicy.topWindowAction(
            windowNumber: 2,
            hit: WindowID(pid: 42, windowNumber: 2),
            isManagedWindow: false
        ) == .ignore)
        #expect(FocusFollowsMousePolicy.topWindowAction(
            windowNumber: 1,
            hit: WindowID(pid: 42, windowNumber: 1),
            isManagedWindow: true
        ) == .focus(WindowID(pid: 42, windowNumber: 1)))
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

    @Test("a sleep-time AX destroy retains the window and its workspace slot")
    @MainActor
    func sleepDropRetainsWindowLayout() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(root: root)
        let id = WindowID(pid: 999_999, windowNumber: 11)
        manager.windowsByID[id] = ManagedWindow(id: id, title: "Editor", bundleID: "example.editor", appName: "Editor", frame: .init(x: 0, y: 0, width: 800, height: 600))
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1")], monitors: [])
        manager.workspaces.setWorkspace(WorkspaceState(id: "1", name: "1", columns: [.init(windows: [id], width: 800)]))
        manager.windowWorkspace[id] = "1"
        manager.prepareForSystemSleep()
        manager.handleUserClosedWindow(id)
        #expect(manager.windowsByID[id] != nil)
        #expect(manager.workspaces.workspaceID(containing: id) == "1")
        #expect(manager.windowWorkspace[id] == "1")
    }

    @Test("resume recovery includes minimized tiles so it can restore their frames")
    @MainActor
    func resumeRecoveryIncludesMinimizedTiles() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(root: root)
        let id = WindowID(pid: 999_998, windowNumber: 12)
        manager.windowsByID[id] = ManagedWindow(
            id: id, title: "Editor", bundleID: "example.editor", appName: "Editor",
            frame: .init(x: 0, y: 0, width: 800, height: 600)
        )
        manager.minimizedCache[id] = true
        manager.isResumeRecovering = true

        #expect(!manager.stackExcludedFromLayout().contains(id))
        manager.isResumeRecovering = false
        #expect(manager.stackExcludedFromLayout().contains(id))
    }

    @Test("a brief missing AX scan does not erase the first workspace tile")
    @MainActor
    func firstMissingScanPreservesTile() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        let manager = WindowManager(runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")), notesStore: NotesStore(root: root.appendingPathComponent("notes")), monitors: MonitorStore(monitors: [monitor]))
        let id = WindowID(pid: 999_910, windowNumber: 1)
        manager.windowsByID[id] = ManagedWindow(id: id, title: "Editor", bundleID: "example.editor", appName: "Editor", frame: monitor.visibleFrame)
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1")], monitors: [monitor])
        manager.workspaces.setWorkspace(WorkspaceState(id: "1", name: "1", columns: [.init(windows: [id], width: 800)]))
        manager.windowWorkspace[id] = "1"
        manager.isBootstrapping = false
        manager.ingest(windows: [])
        #expect(manager.workspaces.workspaceID(containing: id) == "1")
        manager.ingest(windows: [])
        #expect(manager.workspaces.workspaceID(containing: id) == "1")
    }

    @Test("a persistently missing AX window eventually releases its tile")
    @MainActor
    func confirmedMissingScanReleasesTile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        let manager = WindowManager(runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")), notesStore: NotesStore(root: root.appendingPathComponent("notes")), monitors: MonitorStore(monitors: [monitor]))
        let id = WindowID(pid: 999_911, windowNumber: 1)
        manager.windowsByID[id] = ManagedWindow(id: id, title: "Editor", bundleID: "example.editor", appName: "Editor", frame: monitor.visibleFrame)
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1")], monitors: [monitor])
        manager.workspaces.setWorkspace(WorkspaceState(id: "1", name: "1", columns: [.init(windows: [id], width: 800)]))
        manager.windowWorkspace[id] = "1"
        manager.isBootstrapping = false
        manager.ingest(windows: [])
        try await Task.sleep(for: .milliseconds(800))
        manager.ingest(windows: [])
        #expect(manager.workspaces.workspaceID(containing: id) == nil)
    }

    @Test("an AX destroy burst arms wake recovery before removing any window")
    @MainActor
    func destroyBurstPreservesSlots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(root: root)
        defer { manager.cancelPendingResumeRecovery() }
        let ids = [WindowID(pid: 999_991, windowNumber: 1), WindowID(pid: 999_992, windowNumber: 1)]
        manager.isBootstrapping = false
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1")], monitors: [])
        for id in ids {
            manager.windowsByID[id] = ManagedWindow(id: id, title: "Editor", bundleID: "example.\(id.pid)", appName: "Editor", frame: .init(x: 0, y: 0, width: 800, height: 600))
            manager.windowWorkspace[id] = "1"
        }
        manager.workspaces.setWorkspace(WorkspaceState(id: "1", name: "1", columns: ids.map { .init(windows: [$0], width: 600) }))
        for id in ids { manager.axTrackerWindowDidClose(id) }
        try await Task.sleep(for: .milliseconds(80))
        #expect(manager.isResumeRecovering)
        #expect(ids.allSatisfy { manager.windowsByID[$0] != nil && manager.workspaces.workspaceID(containing: $0) == "1" })
    }

    @Test("opening and closing a tile retains the surviving column proportions")
    @MainActor
    func temporaryColumnRestoresWidths() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        let manager = WindowManager(runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")), notesStore: NotesStore(root: root.appendingPathComponent("notes")), monitors: MonitorStore(monitors: [monitor]))
        manager.isBootstrapping = false
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1")], monitors: [monitor])
        let ids = (1...3).map { WindowID(pid: pid_t(999_900 + $0), windowNumber: 1) }
        let usable = manager.engine.usableArea(monitor: monitor.layoutFrame)
        let budget = manager.engine.niri.fillWidthBudget(columnCount: 2, usable: usable)
        for id in ids {
            manager.windowsByID[id] = ManagedWindow(id: id, title: "Tile", bundleID: "example.\(id.pid)", appName: "Tile", frame: usable)
        }
        manager.workspaces.setWorkspace(WorkspaceState(id: "1", name: "1", columns: [
            .init(windows: [ids[0]], width: budget * 0.7),
            .init(windows: [ids[1]], width: budget * 0.3),
        ]))
        manager.windowWorkspace[ids[0]] = "1"
        manager.windowWorkspace[ids[1]] = "1"
        manager.assignWindow(ids[2], to: "1", on: monitor)
        let opened = manager.workspaces.workspaces["1"]!
        #expect(abs(opened.columns[0].width / (opened.columns[0].width + opened.columns[1].width) - 0.7) < 0.04)
        manager.handleUserClosedWindow(ids[2])
        let closed = manager.workspaces.workspaces["1"]!
        #expect(abs(closed.columns[0].width / (closed.columns[0].width + closed.columns[1].width) - 0.7) < 0.01)
    }

    @Test("a compact second document window is not mistaken for a popup")
    @MainActor
    func compactSiblingWindowStillTiles() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        let manager = WindowManager(runtimeState: RuntimeStateStore(url: root.appendingPathComponent("runtime.json")), notesStore: NotesStore(root: root.appendingPathComponent("notes")), monitors: MonitorStore(monitors: [monitor]))
        let id = WindowID(pid: 999_800, windowNumber: 2)
        let window = ManagedWindow(id: id, title: "Downloads", bundleID: "org.filezilla", appName: "FileZilla", frame: .init(x: 100, y: 100, width: 720, height: 430))
        #expect(!manager.isLikelyTransientSameBundleOverlay(id, win: window))
    }

    @Test("resume cannot finish while a saved floating window is missing")
    @MainActor
    func missingFloatingWindowPreventsRecovery() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(root: root)
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1")], monitors: [])
        let missing = RuntimeStateStore.WindowRef(token: "999999:22", bundleID: "example.float", appName: "Float", title: "Inspector")
        manager.runtimeState.setWorkspaceLayout(.init(columns: [], floating: [missing]), for: "1")
        #expect(!manager.layoutLooksRecovered())
        #expect(!manager.layoutContentMatchesDiskSnapshot())
    }

    @Test("a rule-floating window is saved even without a manual float override")
    @MainActor
    func ruleFloatingWindowIsPersisted() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = manager(root: root)
        let id = WindowID(pid: 999_912, windowNumber: 1)
        manager.workspaces.configure(definitions: [.init(id: "1", name: "1")], monitors: [])
        manager.windowsByID[id] = ManagedWindow(id: id, title: "Settings", bundleID: "example.settings", appName: "Settings", frame: .init(x: 100, y: 100, width: 600, height: 500), isFloating: true)
        manager.windowWorkspace[id] = "1"
        manager.writeWorkspaceLayoutSnapshot(wsID: "1", ws: manager.workspaces.workspaces["1"]!)
        #expect(manager.runtimeState.workspaceLayout(for: "1")?.floating.map(\.token) == [id.token])
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
