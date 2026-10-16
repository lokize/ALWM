import Testing
@testable import Alwm

@Suite("Application popup focus handling")
struct AlwmChromeFocusTests {
    @Test("focus follows mouse pauses while an application popup is open")
    @MainActor
    func popupBlocksFocusFollowsMouse() {
        #expect(AlwmChromeFocus.blocksFocusFollowsMouse(
            overlaysCaptureFocus: false,
            paletteVisible: false,
            overviewVisible: false,
            settingsVisible: false,
            appTransientPopupOpen: true
        ))
    }

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
        #expect(FocusFollowsMousePolicy.shouldActivateHomeWorkspace(
            windowHome: "2",
            activeWorkspaces: ["5", "6"]
        ))
        #expect(!FocusFollowsMousePolicy.shouldActivateHomeWorkspace(
            windowHome: "6",
            activeWorkspaces: ["5", "6"]
        ))
        #expect(!FocusFollowsMousePolicy.shouldActivateHomeWorkspace(
            windowHome: nil,
            activeWorkspaces: ["5", "6"]
        ))
    }
}
