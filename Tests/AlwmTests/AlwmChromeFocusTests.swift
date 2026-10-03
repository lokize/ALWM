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
}
