import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

// MARK: - AX window wrapper

public final class AXWindow: @unchecked Sendable {
    public let id: WindowID
    public let element: AXUIElement
    public let pid: pid_t

    public init(id: WindowID, element: AXUIElement, pid: pid_t) {
        self.id = id
        self.element = element
        self.pid = pid
    }

    public var title: String {
        resolvedTitle()
    }

    /// Electron / VS Code / Cursor often leave AXTitle empty — fall back to description,
    /// document path basename, TitleUIElement, then CGWindowList name.
    public func resolvedTitle() -> String {
        if let s = stringAttribute(kAXTitleAttribute as CFString), !s.isEmpty { return s }
        if let s = stringAttribute(kAXDescriptionAttribute as CFString), !s.isEmpty { return s }
        if let s = stringAttribute("AXDocument" as CFString), !s.isEmpty {
            return (s as NSString).lastPathComponent
        }
        if let titleEl = titleUIElement(),
           let s = Self.stringAttribute(on: titleEl, kAXTitleAttribute as CFString)
            ?? Self.stringAttribute(on: titleEl, kAXValueAttribute as CFString),
           !s.isEmpty {
            return s
        }
        if let cg = Self.cgWindowName(windowNumber: id.windowNumber), !cg.isEmpty {
            return cg
        }
        return ""
    }

    func stringAttribute(_ attr: CFString) -> String? {
        Self.stringAttribute(on: element, attr)
    }

    static func stringAttribute(on element: AXUIElement, _ attr: CFString) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success,
              let s = value as? String
        else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func titleUIElement() -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXTitleUIElementAttribute as CFString, &value) == .success,
              let titleElement = AXBridge.element(value)
        else { return nil }
        return titleElement
    }

    static func cgWindowName(windowNumber: Int) -> String? {
        guard windowNumber > 0,
              let infos = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]],
              let info = infos.first,
              let name = info[kCGWindowName as String] as? String
        else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var role: String {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
              let s = value as? String else { return "" }
        return s
    }

    public var subrole: String {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success,
              let s = value as? String else { return "" }
        return s
    }

    public var isMinimized: Bool {
        get {
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success,
                  let b = AXBridge.bool(value) else { return false }
            return b
        }
        set {
            AXUIElementSetAttributeValue(
                element,
                kAXMinimizedAttribute as CFString,
                newValue ? kCFBooleanTrue : kCFBooleanFalse
            )
        }
    }

    public var frame: Rect {
        get {
            var posValue: AnyObject?
            var sizeValue: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
            else {
                return Rect(x: 0, y: 0, width: 0, height: 0)
            }
            return Self.decodeFrame(positionValue: posValue, sizeValue: sizeValue)
                ?? Rect(x: 0, y: 0, width: 0, height: 0)
        }
        set {
            // Electron apps often clamp if position is set before size; size→pos→size is reliable.
            var point = CGPoint(x: newValue.x, y: newValue.y)
            var size = CGSize(width: newValue.width, height: newValue.height)
            if let sz = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sz)
            }
            if let pos = AXValueCreate(.cgPoint, &point) {
                AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pos)
            }
            if let sz = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sz)
            }
        }
    }

    static func decodeFrame(positionValue: AnyObject?, sizeValue: AnyObject?) -> Rect? {
        guard let position = AXBridge.axValue(positionValue),
              let size = AXBridge.axValue(sizeValue),
              AXValueGetType(position) == .cgPoint,
              AXValueGetType(size) == .cgSize
        else { return nil }

        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions)
        else { return nil }
        return Rect(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
    }

    public func focus() {
        // Prefer deminiaturize only after the caller placed geometry (reveal). When we
        // deminiaturize here at park/dock size, macOS clamps a tiny edge strip on-screen.
        if isMinimized {
            let f = frame
            if f.width >= 120, f.height >= 80 {
                isMinimized = false
            }
        }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
        }
        // Last resort: still raise even from a tiny frame (caller should have revealed).
        if isMinimized { isMinimized = false }
    }

    /// Presses the window's close button (same as clicking the red traffic light).
    @discardableResult
    public func close() -> Bool {
        var buttonObj: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &buttonObj) == .success,
              let button = AXBridge.element(buttonObj)
        else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// Accept real app windows; skip system dialogs and tiny junk.
    public var isStandardWindow: Bool {
        let r = role
        guard r == (kAXWindowRole as String) || r == "AXWindow" else { return false }
        if Self.shouldIgnoreWindowLayer(
            cgWindowLayer(),
            menuBarLevel: Int(CGWindowLevelForKey(.mainMenuWindow))
        ) {
            return false
        }
        let s = subrole
        if s == (kAXSystemDialogSubrole as String) || s == "AXSystemDialog" { return false }
        // Standard app windows stay tracked even when miniaturized — AX often reports
        // ~100×30 dock thumbnails (Ghostty/Terminal), which used to drop them entirely
        // and broke Quake adopt/show.
        if s == (kAXStandardWindowSubrole as String) || s == "AXStandardWindow" {
            return true
        }
        let f = frame
        if f.width > 0, f.height > 0, (f.width < 40 || f.height < 40) { return false }
        return true
    }

    /// Menus and other system chrome can expose AXWindow roles, but must not enter
    /// workspace layout as if they were independent app windows.
    static func shouldIgnoreWindowLayer(_ layer: Int?, menuBarLevel: Int) -> Bool {
        guard let layer else { return false }
        // Workspace windows use the normal layer (0). App popovers and menus can
        // live below the menu-bar level, so checking only `>= menuBarLevel` admits
        // those transient windows into tiling.
        return layer != 0 || layer >= menuBarLevel
    }

    /// Open/save panels, sheets, and utility floats should not enter tiling columns.
    public var prefersFloating: Bool {
        Self.prefersFloatingWindow(isModal: isModal, subrole: subrole)
    }

    static func prefersFloatingWindow(isModal: Bool, subrole: String) -> Bool {
        if isModal { return true }
        switch subrole {
        case String(kAXDialogSubrole), "AXDialog",
             String(kAXFloatingWindowSubrole), "AXFloatingWindow",
             String(kAXSystemFloatingWindowSubrole), "AXSystemFloatingWindow":
            return true
        default:
            return false
        }
    }

    /// True when the window exposes a close (traffic-light) button — real documents do; tooltips don't.
    public var hasCloseButton: Bool {
        var buttonObj: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &buttonObj) == .success,
              buttonObj != nil
        else { return false }
        return true
    }

    /// CGWindow layer when known (0 = normal document; 1…23 ≈ panels/tooltips).
    public func cgWindowLayer() -> Int? {
        guard id.windowNumber > 0,
              let infos = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow],
                CGWindowID(id.windowNumber)
              ) as? [[String: Any]],
              let info = infos.first
        else { return nil }
        return (info[kCGWindowLayer as String] as? NSNumber)?.intValue
            ?? (info[kCGWindowLayer as String] as? Int)
    }

    /// Hover tooltips / transient Safari chrome that must never become tiling columns.
    /// Prefer calling from same-bundle sibling paths — some apps omit AX close buttons.
    public var isLikelyTransientOverlay: Bool {
        if prefersFloating { return true }
        if !hasCloseButton { return true }
        if let layer = cgWindowLayer(), layer > 0, layer < 24 { return true }
        return false
    }

    public var isModal: Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXModalAttribute as CFString, &value) == .success,
              let b = AXBridge.bool(value) else { return false }
        return b
    }
}
