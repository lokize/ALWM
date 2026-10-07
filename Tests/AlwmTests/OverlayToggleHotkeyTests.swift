import AppKit
import Foundation
import Testing
@testable import Alwm

@Suite("Overlay toggle hotkeys", .serialized)
struct OverlayToggleHotkeyTests {
    @Test("focusing another window of the same terminal app releases Quake keyboard capture")
    func siblingTerminalDoesNotCaptureKeyboard() {
        let quake = WindowID(pid: 42, windowNumber: 1)
        let regularTerminal = WindowID(pid: 42, windowNumber: 2)
        #expect(!OverlayKeyboardFocus.quakeOwnsKeyboard(bound: quake, focused: regularTerminal, frontmostPID: 42))
        #expect(OverlayKeyboardFocus.quakeOwnsKeyboard(bound: quake, focused: quake, frontmostPID: 42))
        #expect(!OverlayKeyboardFocus.quakeOwnsKeyboard(bound: quake, focused: quake, frontmostPID: 43))
    }

    @Test("workspace switches update tile visibility without releasing overlay focus")
    func workspaceSwitchCanApplyVisibilityDuringOverlayCapture() {
        #expect(OverlayWorkspaceVisibilityPolicy.shouldDefer(overlaysCaptureFocus: true, isWorkspaceSwitch: false))
        #expect(!OverlayWorkspaceVisibilityPolicy.shouldDefer(overlaysCaptureFocus: true, isWorkspaceSwitch: true))
        #expect(!OverlayWorkspaceVisibilityPolicy.shouldDefer(overlaysCaptureFocus: false, isWorkspaceSwitch: false))
    }

    @Test("Option T and Option N emit their toggles while an overlay owns the keyboard")
    @MainActor
    func togglesRemainActiveDuringCapture() async throws {
        let hotkeys = HotkeyManager()
        let bindings = [
            HotkeyBinding(action: "quake.toggle", key: "t", modifiers: ["option"]),
            HotkeyBinding(action: "notepad.toggle", key: "n", modifiers: ["option"]),
            HotkeyBinding(action: "move.to.workspace.2", key: "2", modifiers: ["option", "shift"]),
            HotkeyBinding(action: "workspace.2", key: "2", modifiers: ["option"]),
        ]
        hotkeys.configureBindings(bindings)
        hotkeys.setOverlayKeyboardCapture(true)
        defer { hotkeys.unregisterAll() }
        #expect(hotkeys.keyboardCaptureBindings.map(\.action) == ["quake.toggle", "notepad.toggle", "workspace.2"])
        let events = AsyncStream<String>.makeStream()
        hotkeys.onAction = { events.continuation.yield($0) }
        for key in ["t", "n", "2"] {
            let keyCode = UInt16(try #require(HotkeyManager.keyCode(for: key)))
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .option,
                timestamp: 1, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: keyCode
            ))
            try #require(hotkeys.handleNSEvent(event))
        }
        var iterator = events.stream.makeAsyncIterator()
        #expect(await iterator.next() == "quake.toggle")
        #expect(await iterator.next() == "notepad.toggle")
        #expect(await iterator.next() == "workspace.2")
        let moveWindow = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option, .shift],
            timestamp: 3, windowNumber: 0, context: nil,
            characters: "2", charactersIgnoringModifiers: "2",
            isARepeat: false, keyCode: 19
        ))
        #expect(!hotkeys.handleNSEvent(moveWindow))
        let typing = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 2, windowNumber: 0, context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45))
        #expect(!hotkeys.handleNSEvent(typing))
        hotkeys.setOverlayKeyboardCapture(false)
        #expect(hotkeys.keyboardCaptureBindings == bindings)
    }

    @Test("persistent Notepad toggles open, hidden, and open without creating or discarding notes")
    @MainActor
    func persistentNotepadTogglesWithoutDataLoss() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-toggle-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = NotesStore(root: root)
        let page = notes.createPage(title: "Preserve me")
        let notepad = NotepadController(store: notes)
        var settings = NotepadSettings.default
        settings.animationDuration = 0
        settings.blur = false
        settings.dismissOnClickOutside = false
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        notepad.toggle(settings: settings, monitor: monitor)
        #expect(notepad.isVisible)
        let windowedFrame = notepad.panelFrame(settings: settings, monitor: monitor, visible: true)
        #expect(notepad.toggleFullscreen(settings: settings, monitor: monitor))
        #expect(notepad.isFullscreen)
        let mainHeight = Double(NSScreen.screens.first?.frame.height ?? 900)
        #expect(notepad.panelFrame(settings: settings, monitor: monitor, visible: true)
            == NSRect(x: 0, y: mainHeight - 900, width: 1440, height: 900))
        #expect(!notepad.toggleFullscreen(settings: settings, monitor: monitor))
        #expect(notepad.panelFrame(settings: settings, monitor: monitor, visible: true) == windowedFrame)
        notepad.toggle(settings: settings, monitor: monitor)
        #expect(!notepad.isVisible)
        notepad.toggle(settings: settings, monitor: monitor)
        #expect(notepad.isVisible)
        notepad.hide(settings: settings, monitor: monitor)
        let saved = NotesStore(root: root)
        #expect(saved.index.pages.count == 1)
        #expect(saved.page(page.id)?.title == "Preserve me")
    }

    @Test("Notepad retains overlay capture until its hide animation finishes")
    @MainActor
    func notepadRetainsOverlayCaptureDuringDismissal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-notepad-dismiss-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let notepad = NotepadController(store: NotesStore(root: root))
        var settings = NotepadSettings.default
        settings.animationDuration = 0.25
        settings.blur = false
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        var visibilityChanges: [Bool] = []
        notepad.onVisibilityChanged = { visibilityChanges.append($0) }

        notepad.show(settings: settings, monitor: monitor)
        try await Task.sleep(for: .milliseconds(350))
        #expect(notepad.isVisible)
        #expect(visibilityChanges == [true])

        notepad.hide(settings: settings, monitor: monitor)
        #expect(notepad.isVisible)
        #expect(visibilityChanges == [true])

        try await Task.sleep(for: .milliseconds(350))
        #expect(!notepad.isVisible)
        #expect(visibilityChanges == [true, false])
    }

    @Test("toggling Notepad during dismissal reverses the in-flight animation")
    @MainActor
    func notepadToggleReversesDismissal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-notepad-reverse-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let notepad = NotepadController(store: NotesStore(root: root))
        var settings = NotepadSettings.default
        settings.animationDuration = 0.25
        settings.blur = false
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        var visibilityChanges: [Bool] = []
        notepad.onVisibilityChanged = { visibilityChanges.append($0) }

        notepad.show(settings: settings, monitor: monitor)
        try await Task.sleep(for: .milliseconds(350))
        notepad.hide(settings: settings, monitor: monitor)
        notepad.toggle(settings: settings, monitor: monitor)
        try await Task.sleep(for: .milliseconds(350))

        #expect(notepad.isVisible)
        #expect(notepad.isTargetVisible)
        #expect(visibilityChanges == [true])

        notepad.hide(settings: settings, monitor: monitor)
        try await Task.sleep(for: .milliseconds(350))
        #expect(!notepad.isVisible)
        #expect(visibilityChanges == [true, false])
    }

    @Test("persistent Quake toggles the same terminal session rather than destroying its window")
    @MainActor
    func persistentQuakeTogglesSameSession() {
        let quake = QuakeTerminalController()
        let id = WindowID(pid: 999_999, windowNumber: 1)
        let monitor = MonitorInfo(id: 1, frame: .init(x: 0, y: 0, width: 1440, height: 900), visibleFrame: .init(x: 0, y: 24, width: 1440, height: 876), name: "Test")
        var settings = QuakeSettings.default
        settings.bundleID = "example.test-terminal"
        settings.blur = false
        settings.dismissOnClickOutside = false
        let windows = [id: ManagedWindow(id: id, title: "Shell", bundleID: settings.bundleID, appName: "Shell", frame: monitor.visibleFrame)]
        let ax = AXTracker()
        quake.rebind(id)
        quake.setVisibleForRecovery(true)
        let windowedFrame = quake.visibleFrame(settings: settings, monitor: monitor)
        #expect(quake.toggleFullscreen(settings: settings, monitor: monitor, currentFrame: windowedFrame) == monitor.frame)
        #expect(quake.isFullscreen)
        #expect(quake.visibleFrame(settings: settings, monitor: monitor) == monitor.frame)
        #expect(quake.toggleFullscreen(settings: settings, monitor: monitor, currentFrame: monitor.frame) == windowedFrame)
        #expect(!quake.isFullscreen)
        for expectedVisibility in [false, true, false] {
            quake.toggle(settings: settings, monitor: monitor, windows: windows, ax: ax, applyFrame: { _, _ in }, focusTiled: {})
            #expect(quake.isVisible == expectedVisibility)
            #expect(quake.windowID == id)
        }
        quake.setVisibleForRecovery(false)
    }
}
