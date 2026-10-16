import CoreGraphics
import Testing
@testable import Alwm

@Suite("Application popup focus handling")
struct AlwmChromeFocusTests {
    @Test("a top window covering the focused tile lets focus follow the mouse")
    func topWindowBeatsFocusedTileFrame() {
        #expect(!FocusFollowsMousePolicy.shouldKeepCurrentFocus(pointerInside: true, focusedPID: 42, topPID: 43))
        #expect(FocusFollowsMousePolicy.shouldKeepCurrentFocus(pointerInside: true, focusedPID: 42, topPID: 42))
    }

    @Test("a different window from the focused app does not block mouse focus")
    func siblingWindowDoesNotMasqueradeAsFocusedWindow() {
        #expect(!FocusFollowsMousePolicy.shouldKeepCurrentWindow(
            pointerInside: true,
            focusedWindowNumber: 100,
            topWindowNumber: 200
        ))
        #expect(FocusFollowsMousePolicy.shouldKeepCurrentWindow(
            pointerInside: true,
            focusedWindowNumber: 100,
            topWindowNumber: 100
        ))
    }

    @Test("a mouse hit in an inactive workspace routes through workspace activation")
    func inactiveHomeWorkspaceRequiresActivation() {
        #expect(FocusFollowsMousePolicy.shouldActivateHomeWorkspace(windowHome: "2", activeWorkspaceOnCursor: "6"))
        #expect(FocusFollowsMousePolicy.shouldActivateHomeWorkspace(windowHome: "2", activeWorkspaceOnCursor: nil))
        #expect(!FocusFollowsMousePolicy.shouldActivateHomeWorkspace(
            windowHome: "6",
            activeWorkspaceOnCursor: "6"
        ))
        #expect(!FocusFollowsMousePolicy.shouldActivateHomeWorkspace(windowHome: nil, activeWorkspaceOnCursor: "6"))
    }

    @Test("AX focus on a window from another workspace does not suppress mouse workspace activation")
    func staleAXFocusDoesNotSkipCrossWorkspaceMouseFocus() {
        let hit = WindowID(pid: 42, windowNumber: 100)

        #expect(!FocusFollowsMousePolicy.shouldSkipAlreadyFocusedHit(
            hitHome: "2",
            activeWorkspaceOnCursor: "6",
            focusedWindowOnCursor: hit,
            axFocusedWindow: hit,
            hit: hit
        ))
        #expect(FocusFollowsMousePolicy.shouldSkipAlreadyFocusedHit(
            hitHome: "6",
            activeWorkspaceOnCursor: "6",
            focusedWindowOnCursor: nil,
            axFocusedWindow: hit,
            hit: hit
        ))
    }

    @Test("mouse focus uses Quartz coordinates directly on vertically offset displays")
    func quartzPointerCoordinatesWinOverPrimaryScreenConversion() {
        let lowerDisplayQuartzPoint = CGPoint(x: 900, y: 1_800)
        let mistakenPrimaryScreenConversion = CGPoint(x: 900, y: -360)
        #expect(FocusFollowsMousePolicy.mouseAXPoint(
            quartzPoint: lowerDisplayQuartzPoint,
            cocoaPoint: CGPoint(x: 900, y: 1_800),
            mainScreenHeight: 1_440
        ) == lowerDisplayQuartzPoint)
        #expect(lowerDisplayQuartzPoint != mistakenPrimaryScreenConversion)
    }

    @Test("an unmanaged popup under the pointer prevents focusing a window behind it")
    func unmanagedTopWindowDoesNotFocusWindowBehindPopup() {
        #expect(FocusFollowsMousePolicy.shouldIgnoreUnmanagedTopWindow(
            topWindowNumber: 200,
            isManagedWindow: false
        ))
        #expect(!FocusFollowsMousePolicy.shouldIgnoreUnmanagedTopWindow(
            topWindowNumber: 200,
            isManagedWindow: true
        ))
        #expect(!FocusFollowsMousePolicy.shouldIgnoreUnmanagedTopWindow(
            topWindowNumber: nil,
            isManagedWindow: false
        ))
    }
}
