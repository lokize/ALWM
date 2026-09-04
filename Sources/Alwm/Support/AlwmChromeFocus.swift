import AppKit

/// ALWM-owned dialogs and plugin panels that must retain focus while open.
enum AlwmChromeFocus {
    static func blocksFocusFollowsMouse(
        overlaysCaptureFocus: Bool,
        paletteVisible: Bool,
        overviewVisible: Bool,
        settingsVisible: Bool
    ) -> Bool {
        if overlaysCaptureFocus { return true }
        if paletteVisible || overviewVisible || settingsVisible { return true }
        if let key = NSApp.keyWindow, key.isVisible, !key.isMiniaturized, isInteractiveChrome(key) {
            return true
        }
        return hasVisibleInteractiveWindow()
    }

    /// Settings, plugin panels, color picker, permissions gate, What's New, etc.
    static func hasVisibleInteractiveWindow() -> Bool {
        NSApp.windows.contains { win in
            win.isVisible && !win.isMiniaturized && isInteractiveChrome(win)
        }
    }

    static func isInteractiveChrome(_ win: NSWindow) -> Bool {
        let mask = win.styleMask
        if mask.contains(.borderless), !mask.contains(.titled) { return false }
        if mask.contains(.titled), mask.contains(.closable) || mask.contains(.miniaturizable) {
            return true
        }
        if mask.contains(.utilityWindow), mask.contains(.closable) {
            return true
        }
        return false
    }
}
