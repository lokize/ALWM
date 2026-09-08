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
        guard AXUIElementCopyAttributeValue(element, kAXTitleUIElementAttribute as CFString, &value) == .success
        else { return nil }
        return (value as! AXUIElement)
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
            var point = CGPoint.zero
            var size = CGSize.zero
            // AXValue is a CFType — Swift `as?` always succeeds; trust the AX attribute types.
            AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            return Rect(x: point.x, y: point.y, width: size.width, height: size.height)
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
            app.activate(options: [.activateIgnoringOtherApps])
        }
        // Last resort: still raise even from a tiny frame (caller should have revealed).
        if isMinimized { isMinimized = false }
    }

    /// Presses the window's close button (same as clicking the red traffic light).
    @discardableResult
    public func close() -> Bool {
        var buttonObj: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &buttonObj) == .success,
              let button = buttonObj
        else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Accept real app windows; skip system dialogs and tiny junk.
    public var isStandardWindow: Bool {
        let r = role
        guard r == (kAXWindowRole as String) || r == "AXWindow" else { return false }
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

    /// Open/save panels, sheets, and utility floats should not enter tiling columns.
    public var prefersFloating: Bool {
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

    public var isModal: Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXModalAttribute as CFString, &value) == .success,
              let b = AXBridge.bool(value) else { return false }
        return b
    }
}
