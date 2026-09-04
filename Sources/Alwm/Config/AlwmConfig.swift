import Foundation

public struct HotkeyBinding: Equatable, Sendable, Codable {
    public var action: String
    public var key: String
    public var modifiers: [String]

    public init(action: String, key: String, modifiers: [String]) {
        self.action = action
        self.key = key
        self.modifiers = modifiers
    }
}

public enum WorkspaceLayoutStyle: String, Sendable, Codable, CaseIterable, Identifiable {
    case niri
    case dwindle

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .niri: return "Niri (colunas)"
        case .dwindle: return "Dwindle (BSP)"
        }
    }
}

public struct WorkspaceDefinition: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    /// Layout engine for this workspace.
    public var layout: WorkspaceLayoutStyle
    /// Preferred monitor index (0 = first display). `nil` = auto / any.
    public var monitorIndex: Int?

    public init(
        id: String,
        name: String,
        layout: WorkspaceLayoutStyle = .niri,
        monitorIndex: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.monitorIndex = monitorIndex
    }
}

public enum AppRuleMode: String, Sendable, Codable {
    case tile
    case float
    case ignore
}

public struct AppRule: Equatable, Sendable, Codable {
    public var bundleID: String?
    public var appName: String?
    public var mode: AppRuleMode
    public var workspace: String?
    /// Monitor index (0 = principal), when set with workspace/frame placement.
    public var monitorIndex: Int?
    public var minWidth: Double?
    public var minHeight: Double?
    /// Fixed width/height for float placement (or tile minimum when only size set).
    public var width: Double?
    public var height: Double?
    /// Position offset from the target monitor's visible frame top-left (AX coords).
    public var x: Double?
    public var y: Double?

    public init(
        bundleID: String? = nil,
        appName: String? = nil,
        mode: AppRuleMode = .tile,
        workspace: String? = nil,
        monitorIndex: Int? = nil,
        minWidth: Double? = nil,
        minHeight: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        x: Double? = nil,
        y: Double? = nil
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.mode = mode
        self.workspace = workspace
        self.monitorIndex = monitorIndex
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.width = width
        self.height = height
        self.x = x
        self.y = y
    }

    public func matches(bundleID: String?, appName: String) -> Bool {
        if let bid = self.bundleID, let other = bundleID, bid == other { return true }
        if let name = self.appName, name.caseInsensitiveCompare(appName) == .orderedSame { return true }
        return false
    }

    public var hasFramePlacement: Bool {
        width != nil || height != nil || x != nil || y != nil
    }
}

/// Running app row for the rules settings picker.
public struct AppRuleRunningApp: Identifiable, Equatable, Sendable {
    public var bundleID: String
    public var name: String

    public var id: String { bundleID }

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

/// Snapshot captured from a live window when creating an app rule.
public struct AppRuleCapturedGeometry: Equatable, Sendable {
    public var monitorIndex: Int
    public var workspace: String?
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var isFloating: Bool

    public init(
        monitorIndex: Int,
        workspace: String? = nil,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        isFloating: Bool = false
    ) {
        self.monitorIndex = monitorIndex
        self.workspace = workspace
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isFloating = isFloating
    }
}

public struct AlwmConfig: Equatable, Sendable {
    public var settings: LayoutSettings
    public var hotkeys: [HotkeyBinding]
    public var workspaces: [WorkspaceDefinition]
    public var rules: [AppRule]

    public static let `default` = AlwmConfig(
        settings: .default,
        hotkeys: AlwmConfig.defaultHotkeys,
        workspaces: [
            WorkspaceDefinition(id: "1", name: "1", layout: .niri, monitorIndex: 0),
            WorkspaceDefinition(id: "2", name: "2", layout: .niri, monitorIndex: 0),
            WorkspaceDefinition(id: "3", name: "3", layout: .dwindle, monitorIndex: 0),
            WorkspaceDefinition(id: "4", name: "4", layout: .niri, monitorIndex: 1)
        ],
        rules: [
            AppRule(bundleID: "com.apple.systempreferences", mode: .float),
            AppRule(bundleID: "com.apple.finder", mode: .float),
            AppRule(appName: "Spotlight", mode: .ignore)
        ]
    )

    public static let defaultHotkeys: [HotkeyBinding] = [
        HotkeyBinding(action: "focus.left", key: "left", modifiers: ["option"]),
        HotkeyBinding(action: "focus.right", key: "right", modifiers: ["option"]),
        HotkeyBinding(action: "focus.up", key: "up", modifiers: ["option"]),
        HotkeyBinding(action: "focus.down", key: "down", modifiers: ["option"]),
        HotkeyBinding(action: "focus.left", key: "h", modifiers: ["option"]),
        HotkeyBinding(action: "focus.right", key: "l", modifiers: ["option"]),
        HotkeyBinding(action: "focus.up", key: "k", modifiers: ["option"]),
        HotkeyBinding(action: "focus.down", key: "j", modifiers: ["option"]),
        HotkeyBinding(action: "move.left", key: "left", modifiers: ["option", "shift"]),
        HotkeyBinding(action: "move.right", key: "right", modifiers: ["option", "shift"]),
        HotkeyBinding(action: "move.up", key: "up", modifiers: ["option", "shift"]),
        HotkeyBinding(action: "move.down", key: "down", modifiers: ["option", "shift"]),
    ] + defaultWorkspaceHotkeys + [
        HotkeyBinding(action: "resize.left", key: "-", modifiers: ["option"]),
        HotkeyBinding(action: "resize.right", key: "=", modifiers: ["option"]),
        HotkeyBinding(action: "resize.up", key: "-", modifiers: ["option", "shift"]),
        HotkeyBinding(action: "resize.down", key: "=", modifiers: ["option", "shift"]),
        HotkeyBinding(action: "scroll.left", key: "u", modifiers: ["option"]),
        HotkeyBinding(action: "scroll.right", key: "i", modifiers: ["option"]),
        HotkeyBinding(action: "quake.toggle", key: "t", modifiers: ["option"]),
        HotkeyBinding(action: "notepad.toggle", key: "n", modifiers: ["option"]),
        HotkeyBinding(action: "notepad.new", key: "n", modifiers: ["option", "shift"]),
        HotkeyBinding(action: "palette.toggle", key: "p", modifiers: ["option"]),
        HotkeyBinding(action: "capture.region", key: "4", modifiers: ["control", "command", "shift"]),
        HotkeyBinding(action: "capture.display", key: "3", modifiers: ["control", "command", "shift"]),
        HotkeyBinding(action: "capture.record.toggle", key: "5", modifiers: ["control", "command", "shift"]),
        HotkeyBinding(action: "float.toggle", key: "f", modifiers: ["option"]),
        HotkeyBinding(action: "settings.open", key: ",", modifiers: ["option"])
    ]

    /// Workspaces 1–9: ⌥N · 10: ⌥0 · 11–20: ⌥F1…⌥F10 (move adds ⇧).
    public static let defaultWorkspaceHotkeyCount = 20

    public static var defaultWorkspaceHotkeys: [HotkeyBinding] {
        (1...defaultWorkspaceHotkeyCount).flatMap { n -> [HotkeyBinding] in
            guard let key = workspaceHotkeyKey(number: n) else { return [] }
            let id = String(n)
            return [
                HotkeyBinding(action: "workspace.\(id)", key: key, modifiers: ["option"]),
                HotkeyBinding(action: "move.to.workspace.\(id)", key: key, modifiers: ["option", "shift"]),
            ]
        }
    }

    public static func workspaceHotkeyKey(number n: Int) -> String? {
        switch n {
        case 1...9: return String(n)
        case 10: return "0"
        case 11...20: return "f\(n - 10)"
        default: return nil
        }
    }

    public static func workspaceHotkeyKey(forID id: String) -> String? {
        if let n = Int(id), (1...defaultWorkspaceHotkeyCount).contains(n) {
            return workspaceHotkeyKey(number: n)
        }
        guard id.count == 1, let ch = id.first else { return nil }
        if ch.isNumber { return String(ch) }
        if ch.isLetter { return String(ch).lowercased() }
        return nil
    }
}
