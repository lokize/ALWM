import Foundation

public enum QuakeEdge: String, Sendable, Codable, CaseIterable, Identifiable {
    case top, bottom, left, right

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .top: return L10n.t("quake.edge.top")
        case .bottom: return L10n.t("quake.edge.bottom")
        case .left: return L10n.t("quake.edge.left")
        case .right: return L10n.t("quake.edge.right")
        }
    }
}

public struct QuakeSettings: Equatable, Sendable {
    public var enabled: Bool
    public var bundleID: String
    /// Thickness along the docked edge (height for top/bottom, width for left/right).
    public var sizeRatio: Double
    /// How much of the edge length to cover (1 = full edge).
    public var lengthRatio: Double
    public var animationDuration: Double
    public var inset: Double
    public var edge: QuakeEdge
    /// ALWM draws a blurred backdrop behind the terminal window.
    public var blur: Bool
    /// Strength of the blur backdrop when `blur` is on (0…1).
    public var blurIntensity: Double
    /// Terminal window opacity (0.2…1). Blur is only visible when this is below 1.
    public var opacity: Double

    /// Legacy alias used by older config keys.
    public var heightRatio: Double {
        get { sizeRatio }
        set { sizeRatio = newValue }
    }

    public var widthInset: Double {
        get { inset }
        set { inset = newValue }
    }

    public static let `default` = QuakeSettings(
        enabled: true,
        bundleID: "",
        sizeRatio: 0.4,
        lengthRatio: 1.0,
        animationDuration: 0.16,
        inset: 8,
        edge: .top,
        blur: false,
        blurIntensity: 0.7,
        opacity: 0.92
    )

    public init(
        enabled: Bool,
        bundleID: String,
        sizeRatio: Double,
        lengthRatio: Double,
        animationDuration: Double,
        inset: Double,
        edge: QuakeEdge,
        blur: Bool,
        blurIntensity: Double = 0.7,
        opacity: Double = 0.92
    ) {
        self.enabled = enabled
        self.bundleID = bundleID
        self.sizeRatio = sizeRatio
        self.lengthRatio = lengthRatio
        self.animationDuration = animationDuration
        self.inset = inset
        self.edge = edge
        self.blur = blur
        self.blurIntensity = min(1, max(0, blurIntensity))
        self.opacity = min(1, max(0.2, opacity))
    }

    /// Opacity actually applied to the terminal window.
    /// Blur is invisible at 1.0 — when blur is on, never stay fully solid.
    public var effectiveOpacity: Double {
        let base = min(1, max(0.2, opacity))
        if blur, base > 0.94 { return 0.8 }
        return base
    }
}

public enum GestureDirection: String, Sendable, Codable, CaseIterable, Identifiable {
    case left, right, up, down
    /// Continuous horizontal trackpad scroll (both ways).
    case horizontal
    /// Continuous vertical trackpad scroll (both ways).
    case vertical

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .left: return L10n.t("gestures.dir.left")
        case .right: return L10n.t("gestures.dir.right")
        case .up: return L10n.t("gestures.dir.up")
        case .down: return L10n.t("gestures.dir.down")
        case .horizontal: return L10n.t("gestures.dir.horizontal")
        case .vertical: return L10n.t("gestures.dir.vertical")
        }
    }

    public var isContinuous: Bool {
        self == .horizontal || self == .vertical
    }
}

public struct GestureBinding: Equatable, Sendable, Codable, Identifiable {
    public var id: String
    public var enabled: Bool
    /// Trackpad finger count (2, 3, or 4).
    public var fingers: Int
    public var direction: GestureDirection
    public var action: String

    public init(
        id: String = UUID().uuidString,
        enabled: Bool = true,
        fingers: Int = 2,
        direction: GestureDirection = .horizontal,
        action: String = "scroll.columns"
    ) {
        self.id = id
        self.enabled = enabled
        self.fingers = fingers
        self.direction = direction
        self.action = action
    }

    public static let `default`: [GestureBinding] = [
        // 3 fingers scroll columns; 4 fingers switch workspace (avoids 2-finger macOS scroll).
        GestureBinding(
            id: "3-horizontal-scroll",
            enabled: true,
            fingers: 3,
            direction: .horizontal,
            action: "scroll.columns"
        ),
        GestureBinding(
            id: "3-vertical-stack",
            enabled: true,
            fingers: 3,
            direction: .vertical,
            action: "scroll.stack"
        ),
        GestureBinding(
            id: "4-left-workspace-prev",
            enabled: true,
            fingers: 4,
            direction: .left,
            action: "workspace.prev"
        ),
        GestureBinding(
            id: "4-right-workspace-next",
            enabled: true,
            fingers: 4,
            direction: .right,
            action: "workspace.next"
        )
    ]

    /// Drops redundant bindings (same fingers+direction, or disabled twins of an enabled action+direction).
    public static func deduplicated(_ bindings: [GestureBinding]) -> [GestureBinding] {
        var result: [GestureBinding] = []
        for binding in bindings where binding.enabled {
            let collision = result.contains {
                $0.fingers == binding.fingers && $0.direction == binding.direction
            }
            if !collision {
                result.append(binding)
            }
        }
        for binding in bindings where !binding.enabled {
            if result.contains(where: { $0.fingers == binding.fingers && $0.direction == binding.direction }) {
                continue
            }
            // Hide unused alternate (e.g. 4-finger workspace.next while 3-finger next exists).
            if result.contains(where: { $0.action == binding.action && $0.direction == binding.direction }) {
                continue
            }
            result.append(binding)
        }
        return result
    }
}

public struct GestureSettings: Equatable, Sendable {
    public var enabled: Bool
    public var scrollSnap: Bool
    public var swipeScrollFactor: Double
    public var invertScroll: Bool
    /// Per-gesture mappings (fingers + direction → action).
    public var bindings: [GestureBinding]

    public static let `default` = GestureSettings(
        enabled: true,
        scrollSnap: true,
        swipeScrollFactor: 2.2,
        invertScroll: false,
        bindings: GestureBinding.default
    )

    public init(
        enabled: Bool,
        scrollSnap: Bool,
        swipeScrollFactor: Double,
        invertScroll: Bool,
        bindings: [GestureBinding] = GestureBinding.default
    ) {
        self.enabled = enabled
        self.scrollSnap = scrollSnap
        self.swipeScrollFactor = swipeScrollFactor
        self.invertScroll = invertScroll
        self.bindings = bindings
    }
}

public enum WorkspaceBarPosition: String, Sendable, Codable, CaseIterable, Identifiable {
    case belowMenuBar
    case overlayMenuBar

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .belowMenuBar: return L10n.t("wsbar.pos.below")
        case .overlayMenuBar: return L10n.t("wsbar.pos.overlay")
        }
    }
}

public enum WorkspaceBarAlignment: String, Sendable, Codable, CaseIterable, Identifiable {
    case left, center, right

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .left: return L10n.t("wsbar.align.left")
        case .center: return L10n.t("wsbar.align.center")
        case .right: return L10n.t("wsbar.align.right")
        }
    }
}

public struct WorkspaceBarSettings: Equatable, Sendable {
    public var enabled: Bool
    public var height: Double
    /// Scales chip padding, label font, and app icons (1.0 = default).
    public var widthScale: Double
    public var position: WorkspaceBarPosition
    public var alignment: WorkspaceBarAlignment
    /// Extra horizontal shift in points after alignment (negative = left, positive = right).
    public var horizontalOffset: Double
    public var showLabels: Bool
    public var showAppIcons: Bool
    public var deduplicateAppIcons: Bool
    public var showFocusedStatus: Bool
    public var backgroundOpacity: Double
    public var reserveLayoutSpace: Bool

    public static let `default` = WorkspaceBarSettings(
        enabled: true,
        height: 24,
        widthScale: 1.0,
        position: .overlayMenuBar,
        alignment: .left,
        horizontalOffset: 0,
        showLabels: true,
        showAppIcons: true,
        deduplicateAppIcons: true,
        showFocusedStatus: false,
        backgroundOpacity: 0.0,
        reserveLayoutSpace: false
    )

    public init(
        enabled: Bool,
        height: Double,
        widthScale: Double = 1.0,
        position: WorkspaceBarPosition,
        alignment: WorkspaceBarAlignment,
        horizontalOffset: Double = 0,
        showLabels: Bool,
        showAppIcons: Bool,
        deduplicateAppIcons: Bool,
        showFocusedStatus: Bool,
        backgroundOpacity: Double,
        reserveLayoutSpace: Bool
    ) {
        self.enabled = enabled
        self.height = height
        self.widthScale = min(1.8, max(0.8, widthScale))
        self.position = position
        self.alignment = alignment
        self.horizontalOffset = min(400, max(-400, horizontalOffset))
        self.showLabels = showLabels
        self.showAppIcons = showAppIcons
        self.deduplicateAppIcons = deduplicateAppIcons
        self.showFocusedStatus = showFocusedStatus
        self.backgroundOpacity = min(1, max(0, backgroundOpacity))
        self.reserveLayoutSpace = reserveLayoutSpace
    }
}

public struct BorderSettings: Equatable, Sendable {
    public var enabled: Bool
    public var width: Double
    public var colorHex: String
    /// Unused — border follows the focused window chrome. Kept for old configs.
    public var cornerRadius: Double

    public static let `default` = BorderSettings(
        enabled: true,
        width: 3,
        colorHex: "#4FC3F7",
        cornerRadius: 0
    )

    public init(enabled: Bool, width: Double, colorHex: String, cornerRadius: Double = 0) {
        self.enabled = enabled
        self.width = width
        self.colorHex = colorHex
        self.cornerRadius = cornerRadius
    }
}

public enum AppTheme: String, Sendable, Codable, CaseIterable, Identifiable {
    case system, light, dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return L10n.t("theme.system")
        case .light: return L10n.t("theme.light")
        case .dark: return L10n.t("theme.dark")
        }
    }
}

public struct LayoutSettings: Equatable, Sendable {
    public var gap: Double
    public var outerGap: Double
    public var defaultColumnWidthRatio: Double
    public var minColumnWidth: Double
    public var animationDuration: Double
    public var focusFollowsMouse: Bool
    public var moveMouseToFocusedWindow: Bool
    public var warpCursorOnEmptyWorkspace: Bool
    public var ipcEnabled: Bool
    public var developerMode: Bool
    public var theme: AppTheme
    /// UI language: `system` follows macOS, otherwise an explicit BCP-47 code.
    public var language: AppLanguage
    public var showMenuBarStatusLabel: Bool
    public var preventDisplaySleep: Bool
    /// Open ALWM automatically when the user logs in.
    public var launchAtLogin: Bool
    public var onboardingCompleted: Bool
    public var borders: BorderSettings
    public var workspaceBar: WorkspaceBarSettings
    public var quake: QuakeSettings
    public var notepad: NotepadSettings
    public var gestures: GestureSettings

    /// Legacy alias used by layout engine / bar height reservation.
    public var barHeight: Double {
        get {
            guard workspaceBar.enabled else { return 0 }
            // Overlay sits on the system menu bar — never steal layout space.
            if workspaceBar.position == .overlayMenuBar { return 0 }
            return workspaceBar.reserveLayoutSpace ? workspaceBar.height : 0
        }
        set { workspaceBar.height = newValue }
    }

    public var borderWidth: Double {
        get { borders.width }
        set { borders.width = newValue }
    }

    public var borderColorHex: String {
        get { borders.colorHex }
        set { borders.colorHex = newValue }
    }

    public static let `default` = LayoutSettings(
        gap: 8,
        outerGap: 0,
        defaultColumnWidthRatio: 0.5,
        minColumnWidth: 320,
        animationDuration: 0.18,
        focusFollowsMouse: false,
        moveMouseToFocusedWindow: false,
        warpCursorOnEmptyWorkspace: true,
        ipcEnabled: true,
        developerMode: false,
        theme: .system,
        language: .system,
        showMenuBarStatusLabel: true,
        preventDisplaySleep: false,
        launchAtLogin: true,
        onboardingCompleted: false,
        borders: .default,
        workspaceBar: .default,
        quake: .default,
        notepad: .default,
        gestures: .default
    )

    public init(
        gap: Double,
        outerGap: Double,
        defaultColumnWidthRatio: Double,
        minColumnWidth: Double,
        animationDuration: Double,
        focusFollowsMouse: Bool,
        moveMouseToFocusedWindow: Bool,
        warpCursorOnEmptyWorkspace: Bool,
        ipcEnabled: Bool,
        developerMode: Bool,
        theme: AppTheme,
        language: AppLanguage = .system,
        showMenuBarStatusLabel: Bool,
        preventDisplaySleep: Bool,
        launchAtLogin: Bool,
        onboardingCompleted: Bool,
        borders: BorderSettings,
        workspaceBar: WorkspaceBarSettings,
        quake: QuakeSettings,
        notepad: NotepadSettings,
        gestures: GestureSettings
    ) {
        self.gap = gap
        self.outerGap = outerGap
        self.defaultColumnWidthRatio = defaultColumnWidthRatio
        self.minColumnWidth = minColumnWidth
        self.animationDuration = animationDuration
        self.focusFollowsMouse = focusFollowsMouse
        self.moveMouseToFocusedWindow = moveMouseToFocusedWindow
        self.warpCursorOnEmptyWorkspace = warpCursorOnEmptyWorkspace
        self.ipcEnabled = ipcEnabled
        self.developerMode = developerMode
        self.theme = theme
        self.language = language
        self.showMenuBarStatusLabel = showMenuBarStatusLabel
        self.preventDisplaySleep = preventDisplaySleep
        self.launchAtLogin = launchAtLogin
        self.onboardingCompleted = onboardingCompleted
        self.borders = borders
        self.workspaceBar = workspaceBar
        self.quake = quake
        self.notepad = notepad
        self.gestures = gestures
    }
}

public struct FrameAssignment: Equatable, Sendable {
    public var windowID: WindowID
    public var frame: Rect
    public var visible: Bool

    public init(windowID: WindowID, frame: Rect, visible: Bool) {
        self.windowID = windowID
        self.frame = frame
        self.visible = visible
    }
}
