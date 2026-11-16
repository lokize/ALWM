import CoreGraphics
import Testing
@testable import Alwm

@Suite("Persistent overlay click-through")
struct OverlayClickPassThroughTests {
    private let overlay = Rect(x: 100, y: 100, width: 500, height: 300)

    @Test("outside mouse-down passes to another app when click-away is disabled")
    func outsideClickPassesThroughPersistentOverlay() {
        #expect(!OverlayClickCapturePolicy.shouldInstallEventTap(
            visibleFrames: [overlay], dismissOnClickOutside: false
        ))
        #expect(!OverlayClickCapturePolicy.shouldConsumeOutsideClick(
            pointX: 700,
            pointY: 200,
            visibleFrames: [overlay],
            dismissOnClickOutside: false,
            frontmostWindowOwnerPID: 99,
            ownProcessID: 42
        ))
    }

    @Test("auto-dismiss still consumes the first outside click")
    func autoDismissStillConsumesOutsideClick() {
        #expect(OverlayClickCapturePolicy.shouldInstallEventTap(
            visibleFrames: [overlay], dismissOnClickOutside: true
        ))
        #expect(OverlayClickCapturePolicy.shouldConsumeOutsideClick(
            pointX: 700,
            pointY: 200,
            visibleFrames: [overlay],
            dismissOnClickOutside: true,
            frontmostWindowOwnerPID: 99,
            ownProcessID: 42
        ))
    }

    @Test("a dismissible overlay does not block clicks inside a persistent sibling")
    func mixedOverlayClickTargets() {
        let persistent = Rect(x: 650, y: 100, width: 300, height: 300)
        #expect(!OverlayClickCapturePolicy.shouldConsumeOutsideClick(
            pointX: 700,
            pointY: 200,
            visibleFrames: [overlay, persistent],
            dismissOnClickOutside: true,
            frontmostWindowOwnerPID: 99,
            ownProcessID: 42
        ))
    }

    @Test("Notepad containsClick correctly distinguishes AX coordinate inside vs outside")
    @MainActor
    func notepadContainsClickUsesAXCoordinates() {
        let controller = NotepadController()
        var settings = NotepadSettings.default
        settings.enabled = true
        let monitor = MonitorInfo(
            id: 1,
            frame: Rect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: Rect(x: 0, y: 25, width: 1920, height: 1055),
            name: "Main"
        )
        controller.show(settings: settings, monitor: monitor)
        defer { controller.hide(settings: settings, monitor: monitor) }

        guard let axFrame = controller.visibleAXFrame(settings: settings) else {
            Issue.record("visibleAXFrame should not be nil when visible")
            return
        }

        // Inside the panel in AX coordinates:
        let insidePoint = CGPoint(x: axFrame.midX, y: axFrame.midY)
        #expect(controller.containsClick(at: insidePoint, settings: settings, monitor: monitor))

        // Outside the panel at the bottom of the screen in AX coordinates:
        let outsidePoint = CGPoint(x: 960, y: 900)
        #expect(!controller.containsClick(at: outsidePoint, settings: settings, monitor: monitor))
    }

    @Test("menu bar clicks are never consumed so status bar menus remain clickable")
    func menuBarClicksPassThrough() {
        let overlay = Rect(x: 100, y: 100, width: 500, height: 300)
        // Click at top of screen in system menu bar strip (y <= 32 in AX coordinates)
        #expect(!OverlayClickCapturePolicy.shouldConsumeOutsideClick(
            pointX: 500,
            pointY: 15,
            visibleFrames: [overlay],
            dismissOnClickOutside: true,
            frontmostWindowOwnerPID: 99,
            ownProcessID: 42
        ))
    }
}
