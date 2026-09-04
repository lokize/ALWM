import Foundation

public struct WindowID: Hashable, Sendable, Codable {
    public let pid: Int32
    public let windowNumber: Int

    public init(pid: Int32, windowNumber: Int) {
        self.pid = pid
        self.windowNumber = windowNumber
    }

    public var token: String { "\(pid):\((windowNumber))" }
}

public struct ManagedWindow: Equatable, Sendable {
    public var id: WindowID
    public var title: String
    public var bundleID: String?
    public var appName: String
    public var frame: Rect
    public var isFloating: Bool
    public var isIgnored: Bool
    public var isScratchpad: Bool
    public var minSize: Size

    public init(
        id: WindowID,
        title: String,
        bundleID: String?,
        appName: String,
        frame: Rect,
        isFloating: Bool = false,
        isIgnored: Bool = false,
        isScratchpad: Bool = false,
        minSize: Size = Size(width: 200, height: 120)
    ) {
        self.id = id
        self.title = title
        self.bundleID = bundleID
        self.appName = appName
        self.frame = frame
        self.isFloating = isFloating
        self.isIgnored = isIgnored
        self.isScratchpad = isScratchpad
        self.minSize = minSize
    }

    public var isTiled: Bool { !isFloating && !isIgnored && !isScratchpad }
}

public struct Column: Equatable, Sendable {
    public var windows: [WindowID]
    public var width: Double
    /// Focused window fills the whole column (siblings parked) - fill / zoom-parent.
    public var isMaximized: Bool
    /// Unused legacy field (kept for runtime-state compatibility).
    public var restoreWidth: Double

    public init(
        windows: [WindowID] = [],
        width: Double = 0,
        isMaximized: Bool = false,
        restoreWidth: Double = 0
    ) {
        self.windows = windows
        self.width = width
        self.isMaximized = isMaximized
        self.restoreWidth = restoreWidth
    }
}

public struct WorkspaceState: Equatable, Sendable {
    public var id: String
    public var name: String
    public var layout: WorkspaceLayoutStyle
    public var columns: [Column]
    public var focusedColumn: Int
    public var focusedWindowInColumn: [Int: Int]
    public var viewOffset: Double
    /// Relative leaf sizes for dwindle BSP (`WindowID.token` → weight).
    public var leafWeights: [String: Double]

    public init(
        id: String,
        name: String,
        layout: WorkspaceLayoutStyle = .niri,
        columns: [Column] = [],
        focusedColumn: Int = 0,
        focusedWindowInColumn: [Int: Int] = [:],
        viewOffset: Double = 0,
        leafWeights: [String: Double] = [:]
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.columns = columns
        self.focusedColumn = focusedColumn
        self.focusedWindowInColumn = focusedWindowInColumn
        self.viewOffset = viewOffset
        self.leafWeights = leafWeights
    }

    public var focusedWindowID: WindowID? {
        guard !columns.isEmpty else { return nil }
        let col = min(max(0, focusedColumn), columns.count - 1)
        let wins = columns[col].windows
        guard !wins.isEmpty else { return nil }
        let row = focusedWindowInColumn[col] ?? 0
        return wins[min(max(0, row), wins.count - 1)]
    }

    /// Flattened window order (insertion / BSP leaf order).
    public var orderedWindowIDs: [WindowID] {
        columns.flatMap(\.windows)
    }
}
