import Testing
@testable import Alwm

@Suite("Overlay dismissal settings")
struct OverlayDismissSettingsTests {
    @Test("click-away dismissal can be independently disabled and defaults on")
    func parsesClickAwayDismissalSettings() throws {
        let settings = try ConfigStore.parseSettings("""
        quakeDismissOnClickOutside = false
        notepadDismissOnClickOutside = false
        """)

        #expect(settings.quake.dismissOnClickOutside == false)
        #expect(settings.notepad.dismissOnClickOutside == false)
        #expect(LayoutSettings.default.quake.dismissOnClickOutside)
        #expect(LayoutSettings.default.notepad.dismissOnClickOutside)
    }

    @Test("settings serialization persists both dismissal choices")
    func serializesClickAwayDismissalSettings() throws {
        var settings = LayoutSettings.default
        settings.quake.dismissOnClickOutside = false
        settings.notepad.dismissOnClickOutside = false

        let saved = try ConfigStore.parseSettings(ConfigWriter.settingsTOML(settings))

        #expect(!saved.quake.dismissOnClickOutside)
        #expect(!saved.notepad.dismissOnClickOutside)
    }
}
