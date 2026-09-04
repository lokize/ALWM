import AppKit
import ApplicationServices

/// Reads live menu-bar geometry (app menus + inline document title) for overlay placement.
enum MenuBarLayout {
    // Workspace bar runs on the main thread; cache is only touched from AppKit UI paths.
    private nonisolated(unsafe) static var cachedTitleX: CGFloat?
    private nonisolated(unsafe) static var cachedAt: CFAbsoluteTime = 0
    private nonisolated(unsafe) static var cachedScreen: NSRect = .zero
    private nonisolated(unsafe) static var cachedMenuHeight: CGFloat = 0
    private static let cacheTTL: CFAbsoluteTime = 2.0

    /// Screen X where the focused app's inline document title begins, if visible.
    /// Results are cached briefly — AX walks here must not run on every chrome refresh.
    static func documentTitleLeadingX(screenFrame: NSRect, menuHeight: CGFloat) -> CGFloat? {
        let now = CFAbsoluteTimeGetCurrent()
        if now - cachedAt < cacheTTL,
           abs(cachedScreen.minX - screenFrame.minX) < 0.5,
           abs(cachedScreen.width - screenFrame.width) < 0.5,
           abs(cachedMenuHeight - menuHeight) < 0.5 {
            return cachedTitleX
        }
        let value = measureDocumentTitleLeadingX(screenFrame: screenFrame, menuHeight: menuHeight)
        cachedTitleX = value
        cachedAt = now
        cachedScreen = screenFrame
        cachedMenuHeight = menuHeight
        return value
    }

    /// Cheap signature token — last measured value only (never forces a fresh AX walk).
    static func cachedTitleToken() -> String {
        if let x = cachedTitleX { return "tx=\(Int(x))" }
        return "tx=-"
    }

    private static func measureDocumentTitleLeadingX(screenFrame: NSRect, menuHeight: CGFloat) -> CGFloat? {
        guard AXIsProcessTrusted() else { return nil }
        guard let menuBar = focusedMenuBar() else { return nil }
        guard let app = menuBarApp(menuBar) else { return nil }

        let windowTitle = normalized(focusedWindowTitle(app: app))
        guard !windowTitle.isEmpty else { return nil }

        let menusTrailing = appMenusTrailingX(in: menuBar) ?? 0
        guard let children = menuBarChildren(menuBar) else { return nil }

        let menuStrip = NSRect(
            x: screenFrame.minX,
            y: screenFrame.maxY - menuHeight - 4,
            width: screenFrame.width,
            height: menuHeight + 8
        )

        var best: (x: CGFloat, score: Int)?
        for child in children {
            guard elementRole(child) != kAXMenuBarItemRole as String,
                  let frame = elementFrame(child),
                  frame.width > 28,
                  frame.height > 8,
                  menuStrip.intersects(frame),
                  frame.minX >= menusTrailing - 6
            else { continue }

            let label = normalized(elementLabel(child))
            var score = 0
            if !label.isEmpty {
                if label == windowTitle { score = 100 }
                else if label.hasPrefix(String(windowTitle.prefix(min(16, windowTitle.count)))) { score = 85 }
                else if windowTitle.hasPrefix(label) { score = 70 }
                else if titlesLooselyMatch(label, windowTitle) { score = 55 }
            }
            let role = elementRole(child) ?? ""
            if role == "AXStaticText" || role == "AXTitleUIElement" { score += 10 }

            guard score >= 55 else { continue }
            if best == nil || score > best!.score || (score == best!.score && frame.minX < best!.x) {
                best = (frame.minX, score)
            }
        }
        return best?.x
    }

    private static func focusedMenuBar() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var appObject: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appObject) == .success
        else { return nil }
        let app = appObject as! AXUIElement
        var barObject: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &barObject) == .success else { return nil }
        return (barObject as! AXUIElement)
    }

    private static func menuBarApp(_ menuBar: AXUIElement) -> AXUIElement? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(menuBar, &pid) == .success else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    private static func focusedWindowTitle(app: AXUIElement) -> String {
        var windowObject: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowObject) == .success,
              let window = windowObject
        else { return "" }
        return elementLabel(window as! AXUIElement)
    }

    private static func appMenusTrailingX(in menuBar: AXUIElement) -> CGFloat? {
        guard let children = menuBarChildren(menuBar) else { return nil }
        var maxTrailing: CGFloat = 0
        for child in children {
            guard elementRole(child) == kAXMenuBarItemRole as String,
                  let frame = elementFrame(child),
                  frame.width > 0.5,
                  frame.height > 0.5
            else { continue }
            maxTrailing = max(maxTrailing, frame.maxX)
        }
        return maxTrailing > 8 ? maxTrailing : nil
    }

    private static func menuBarChildren(_ menuBar: AXUIElement) -> [AXUIElement]? {
        var childrenObject: AnyObject?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenObject) == .success,
              let children = childrenObject as? [AXUIElement]
        else { return nil }
        return children
    }

    private static func elementRole(_ element: AXUIElement) -> String? {
        var roleObject: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleObject) == .success,
              let role = roleObject as? String
        else { return nil }
        return role
    }

    private static func elementLabel(_ element: AXUIElement) -> String {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] as [CFString] {
            var valueObject: AnyObject?
            guard AXUIElementCopyAttributeValue(element, attr, &valueObject) == .success,
                  let text = valueObject as? String
            else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var posObject: AnyObject?
        var sizeObject: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posObject) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeObject) == .success,
              CFGetTypeID(posObject) == AXValueGetTypeID(),
              CFGetTypeID(sizeObject) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posObject as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeObject as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{200e}", with: "")
            .replacingOccurrences(of: "\u{200f}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func titlesLooselyMatch(_ a: String, _ b: String) -> Bool {
        let al = normalized(a).lowercased()
        let bl = normalized(b).lowercased()
        guard !al.isEmpty, !bl.isEmpty else { return false }
        if al == bl { return true }
        if al.contains(bl) || bl.contains(al) { return true }
        let prefix = zip(al, bl).prefix(while: { $0 == $1 }).count
        return prefix >= 10
    }
}
