import AppKit
import ApplicationServices
import AlwmPluginAPI

/// ALWM-owned dialogs, plugin panels, and app transient menus that must pause focus-follows-mouse.
@MainActor
enum AlwmChromeFocus {
    private static var menuBarOpenCache: (at: Date, value: Bool)?

    static func blocksFocusFollowsMouse(
        overlaysCaptureFocus: Bool,
        paletteVisible: Bool,
        overviewVisible: Bool,
        settingsVisible: Bool,
        statusPopoverVisible: Bool = false,
        appTransientPopupOpen: Bool = false
    ) -> Bool {
        if overlaysCaptureFocus { return true }
        if paletteVisible || overviewVisible || settingsVisible { return true }
        if statusPopoverVisible { return true }
        if PluginPanelOutsideClick.hasVisiblePanel { return true }
        if appTransientPopupOpen { return true }
        //  menu and File/Edit/… app menus — moving the mouse must not raise tiles underneath.
        if menuBarMenuIsOpen() { return true }
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
        // A persistent terminal's tiny dismissal accessory is not a dialog.
        if win.identifier?.rawValue == "alwm.quake.dismiss" || win.identifier?.rawValue == "alwm.quake.controls" { return false }
        // Focus border / workspace bar / other HUD that ignore mouse must never block FFM.
        if win.ignoresMouseEvents { return false }

        let mask = win.styleMask
        if mask.contains(.titled), mask.contains(.closable) || mask.contains(.miniaturizable) {
            return true
        }
        if mask.contains(.utilityWindow), mask.contains(.closable) {
            return true
        }
        // Plugin panels: borderless + nonactivatingPanel / utility at floating level.
        if mask.contains(.nonactivatingPanel) || mask.contains(.utilityWindow) {
            if win.level.rawValue >= NSWindow.Level.floating.rawValue {
                return true
            }
        }
        if mask.contains(.borderless), !mask.contains(.titled) {
            return false
        }
        return false
    }

    /// Apple menu () or any open menu-bar dropdown (File, Edit, …).
    static func menuBarMenuIsOpen() -> Bool {
        if let cached = menuBarOpenCache, Date().timeIntervalSince(cached.at) < 0.12 {
            return cached.value
        }
        let value = cgMenuBarDropdownIsOpen() || axFrontmostMenuBarHasOpenMenu()
        menuBarOpenCache = (Date(), value)
        return value
    }

    /// Menu-level CG windows taller than the thin menu-bar strip = open dropdown.
    private static func cgMenuBarDropdownIsOpen() -> Bool {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for info in infos {
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
                ?? (info[kCGWindowLayer as String] as? Int)
                ?? 0
            // Menu bar / menu window level is typically 24–25.
            guard layer >= 24, layer <= 26 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { continue }
            let w = (bounds["Width"] as? NSNumber)?.doubleValue ?? (bounds["Width"] as? Double) ?? 0
            let h = (bounds["Height"] as? NSNumber)?.doubleValue ?? (bounds["Height"] as? Double) ?? 0
            // Strip itself is ~22–30pt tall; open Apple/app menus are much taller.
            if w >= 80, h >= 48 { return true }
        }
        return false
    }

    /// AX: a selected menu-bar item means its menu is pulled down (, File, Edit, …).
    private static func axFrontmostMenuBarHasOpenMenu() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let app = AXUIElementCreateApplication(pid)
        var barObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barObj) == .success,
              let bar = barObj
        else { return false }
        let menuBar = unsafeBitCast(bar, to: AXUIElement.self)

        var childrenObj: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenObj) == .success,
              let children = childrenObj as? [AXUIElement]
        else { return false }

        for item in children {
            var selectedObj: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXSelectedAttribute as CFString, &selectedObj) == .success,
               let selected = selectedObj as? Bool,
               selected {
                return true
            }
            // Fallback: visible AXMenu child with a real size.
            var itemChildrenObj: CFTypeRef?
            guard AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &itemChildrenObj) == .success,
                  let kids = itemChildrenObj as? [AXUIElement]
            else { continue }
            for kid in kids {
                var roleObj: CFTypeRef?
                guard AXUIElementCopyAttributeValue(kid, kAXRoleAttribute as CFString, &roleObj) == .success,
                      let role = roleObj as? String,
                      role == (kAXMenuRole as String) || role == "AXMenu"
                else { continue }
                var sizeObj: CFTypeRef?
                guard AXUIElementCopyAttributeValue(kid, kAXSizeAttribute as CFString, &sizeObj) == .success,
                      let sizeValue = sizeObj,
                      CFGetTypeID(sizeValue) == AXValueGetTypeID()
                else { continue }
                var size = CGSize.zero
                let axSize = unsafeBitCast(sizeValue, to: AXValue.self)
                if AXValueGetValue(axSize, .cgSize, &size), size.width >= 40, size.height >= 40 {
                    return true
                }
            }
        }
        return false
    }

    /// On-screen popup/menu layer windows for an app (Electron sticker pickers, Discord menus, …).
    static func cgProcessHasPopupLayerWindow(pid: pid_t, managedWindowNumbers: Set<Int> = []) -> Bool {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        return processHasPopupWindow(pid: pid, infos: infos, managedWindowNumbers: managedWindowNumbers)
    }

    static func processHasPopupWindow(
        pid: pid_t,
        infos: [[String: Any]],
        managedWindowNumbers: Set<Int>
    ) -> Bool {
        for info in infos {
            let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                ?? (info[kCGWindowOwnerPID as String] as? pid_t)
            guard owner == pid else { continue }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
                ?? (info[kCGWindowLayer as String] as? Int)
                ?? 0
            // 0 = normal; ≥24 = menu bar / open menus (handled separately).
            let number = (info[kCGWindowNumber as String] as? NSNumber)?.intValue
            let untrackedNormalPanel = layer == 0 && !managedWindowNumbers.isEmpty
                && number.map { !managedWindowNumbers.contains($0) } == true
            guard (layer > 0 && layer < 24) || untrackedNormalPanel else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue <= 0 { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any] else { continue }
            let w = (bounds["Width"] as? NSNumber)?.doubleValue ?? (bounds["Width"] as? Double) ?? 0
            let h = (bounds["Height"] as? NSNumber)?.doubleValue ?? (bounds["Height"] as? Double) ?? 0
            // Ignore tiny tooltips / shadows.
            if w >= 48, h >= 48 { return true }
        }
        return false
    }

    /// Some Electron popups are drawn inside the document's CGWindow. Inspect
    /// focus ancestry and sheets, not the entire (potentially huge) UI tree.
    static func axProcessHasTransientPopup(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.015)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.04
        func attribute(_ element: AXUIElement, _ name: CFString) -> AnyObject? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
            return value
        }
        var node = AXBridge.element(attribute(app, kAXFocusedUIElementAttribute as CFString))
        for _ in 0..<12 {
            guard let element = node else { break }
            let role = attribute(element, kAXRoleAttribute as CFString) as? String ?? ""
            let subrole = attribute(element, kAXSubroleAttribute as CFString) as? String ?? ""
            if ["AXMenu", "AXMenuItem", "AXPopover", "AXSheet", "AXDialog"].contains(role)
                || ["AXDialog", "AXSystemDialog"].contains(subrole) {
                return true
            }
            if ["AXPopUpButton", "AXComboBox"].contains(role),
               AXBridge.bool(attribute(element, kAXExpandedAttribute as CFString)) == true { return true }
            node = AXBridge.element(attribute(element, kAXParentAttribute as CFString))
        }
        if let window = AXBridge.element(attribute(app, kAXFocusedWindowAttribute as CFString)) {
            if AXBridge.bool(attribute(window, kAXModalAttribute as CFString)) == true { return true }
            if let children = attribute(window, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                for child in children.prefix(32) {
                    if attribute(child, kAXRoleAttribute as CFString) as? String == "AXSheet" { return true }
                }
            }
        }
        return false
    }
}
