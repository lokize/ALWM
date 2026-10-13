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
}
