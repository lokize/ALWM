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
}
