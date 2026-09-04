import Foundation

public enum AppRules {
    public static func matching(rules: [AppRule], window: ManagedWindow) -> AppRule? {
        rules.first { $0.matches(bundleID: window.bundleID, appName: window.appName) }
    }

    public static func apply(rules: [AppRule], to window: ManagedWindow) -> ManagedWindow {
        var w = window
        if let rule = matching(rules: rules, window: window) {
            switch rule.mode {
            case .float:
                w.isFloating = true
            case .ignore:
                w.isIgnored = true
            case .tile:
                w.isFloating = false
                w.isIgnored = false
            }
            if let mw = rule.minWidth ?? rule.width, let mh = rule.minHeight ?? rule.height {
                w.minSize = Size(width: mw, height: mh)
            } else if let mw = rule.minWidth ?? rule.width {
                w.minSize = Size(width: mw, height: w.minSize.height)
            } else if let mh = rule.minHeight ?? rule.height {
                w.minSize = Size(width: w.minSize.width, height: mh)
            }
        }
        return w
    }

    public static func forcesFloat(rules: [AppRule], window: ManagedWindow) -> Bool {
        rules.contains { rule in
            rule.mode == .float && rule.matches(bundleID: window.bundleID, appName: window.appName)
        }
    }

    public static func preferredWorkspace(rules: [AppRule], window: ManagedWindow) -> String? {
        guard let raw = matching(rules: rules, window: window)?.workspace else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func preferredMonitorIndex(rules: [AppRule], window: ManagedWindow) -> Int? {
        matching(rules: rules, window: window)?.monitorIndex
    }

    /// Target frame in AX coordinates for float / fixed placement rules.
    public static func targetFrame(rule: AppRule, monitor: MonitorInfo, fallback: Rect) -> Rect? {
        guard rule.hasFramePlacement else { return nil }
        let bounds = monitor.visibleFrame
        let w = max(160, min(rule.width ?? fallback.width, bounds.width))
        let h = max(120, min(rule.height ?? fallback.height, bounds.height))

        let x: Double
        let y: Double
        if let rx = rule.x, let ry = rule.y {
            x = bounds.x + rx
            y = bounds.y + ry
        } else if rule.width != nil || rule.height != nil {
            x = bounds.x + (bounds.width - w) / 2
            y = bounds.y + (bounds.height - h) / 2
        } else {
            x = fallback.x
            y = fallback.y
        }
        return Rect(x: x, y: y, width: w, height: h).clamped(to: bounds)
    }

    /// Convert absolute AX frame to rule offsets on a monitor.
    public static func geometry(from frame: Rect, on monitor: MonitorInfo, monitorIndex: Int) -> AppRuleCapturedGeometry {
        AppRuleCapturedGeometry(
            monitorIndex: monitorIndex,
            x: frame.x - monitor.visibleFrame.x,
            y: frame.y - monitor.visibleFrame.y,
            width: frame.width,
            height: frame.height
        )
    }

    public static func applyCapture(_ captured: AppRuleCapturedGeometry, to rule: inout AppRule) {
        rule.monitorIndex = captured.monitorIndex
        if let ws = captured.workspace?.trimmingCharacters(in: .whitespacesAndNewlines), !ws.isEmpty {
            rule.workspace = ws
        }
        rule.x = captured.x
        rule.y = captured.y
        rule.width = captured.width
        rule.height = captured.height
        rule.mode = captured.isFloating ? .float : .tile
    }
}
