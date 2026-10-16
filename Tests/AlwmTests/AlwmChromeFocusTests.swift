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

    @Test("a stale focused window from another workspace cannot block hover focus")
    func staleFocusedWindowDoesNotBlockOtherWorkspace() {
        #expect(!FocusFollowsMousePolicy.shouldKeepCurrentWindow(
            pointerInside: true,
            focusedWindowNumber: 100,
            topWindowNumber: 100,
            currentWindowHome: "5",
            activeWorkspaceOnCursor: "2"
        ))
        #expect(FocusFollowsMousePolicy.shouldKeepCurrentWindow(
            pointerInside: true,
            focusedWindowNumber: 100,
            topWindowNumber: 100,
            currentWindowHome: "2",
            activeWorkspaceOnCursor: "2"
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

    @Test("an exact managed WindowServer hit selects the direct focus path")
    func managedTopWindowTakesTheFastFocusPath() {
        let hovered = WindowID(pid: 43, windowNumber: 201)
        let action = FocusFollowsMousePolicy.topWindowAction(
            windowNumber: hovered.windowNumber,
            hit: hovered,
            isManagedWindow: true
        )

        #expect(action == .focus(hovered))
        #expect(FocusFollowsMousePolicy.topWindowAction(
            windowNumber: hovered.windowNumber,
            hit: hovered,
            isManagedWindow: false
        ) == .ignore)
        #expect(FocusFollowsMousePolicy.topWindowAction(
            windowNumber: 0,
            hit: nil,
            isManagedWindow: false
        ) == .fallback)
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
        let popup = WindowID(pid: 43, windowNumber: 200)
        #expect(FocusFollowsMousePolicy.topWindowAction(
            windowNumber: popup.windowNumber,
            hit: popup,
            isManagedWindow: false
        ) == .ignore)
        #expect(FocusFollowsMousePolicy.topWindowAction(
            windowNumber: nil,
            hit: nil,
            isManagedWindow: false
        ) == .fallback)
    }
}
