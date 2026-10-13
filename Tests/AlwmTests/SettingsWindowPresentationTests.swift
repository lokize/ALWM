import AppKit
import Testing
@testable import Alwm

@Suite("Settings window presentation", .serialized)
struct SettingsWindowPresentationTests {
    @Test("settings window stays above workspace apps")
    @MainActor
    func settingsWindowFloatsAboveNormalWindows() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let controller = SettingsWindowController()
        controller.open(config: .default)
        defer { controller.close() }

        let window = try #require(controller.window)
        #expect(window.level.rawValue >= NSWindow.Level.statusBar.rawValue)
    }

    @Test("wallpaper directory picker stays above settings and app windows")
    @MainActor
    func wallpaperPickerUsesModalLevel() {
        _ = NSApplication.shared
        let panel = NSOpenPanel()
        WallpaperDirectoryPickerPresentation.configure(panel)
        #expect(panel.level.rawValue >= NSWindow.Level.statusBar.rawValue)
    }

    @Test("persistent Notepad stays above app windows after it loses keyboard focus")
    @MainActor
    func persistentNotepadStaysAboveNormalWindows() {
        _ = NSApplication.shared
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        NotepadController.configurePanelPresentation(panel)

        #expect(panel.level.rawValue >= NSWindow.Level.statusBar.rawValue)
        #expect(!panel.hidesOnDeactivate)
    }

    @Test("Quake raises only its Ghostty window while visible")
    func quakeFloatOnTopIsIdempotent() {
        #expect(QuakeShellAppearance.shouldToggleFloatOnTop(
            currentLayer: 0,
            enable: true,
            floatingLayer: 3
        ))
        #expect(!QuakeShellAppearance.shouldToggleFloatOnTop(
            currentLayer: 3,
            enable: true,
            floatingLayer: 3
        ))
        #expect(QuakeShellAppearance.shouldToggleFloatOnTop(
            currentLayer: 3,
            enable: false,
            floatingLayer: 3
        ))
        #expect(!QuakeShellAppearance.shouldToggleFloatOnTop(
            currentLayer: 0,
            enable: false,
            floatingLayer: 3
        ))
        #expect(QuakeShellAppearance.ghosttyFloatOnTopScript.contains(
            "perform action \"toggle_window_float_on_top\""
        ))
        #expect(!QuakeShellAppearance.ghosttyQuakeConfigContents(settings: .default)
            .contains("keybind ="))
    }
}
