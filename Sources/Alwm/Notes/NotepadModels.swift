import Foundation

public enum BlockKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case paragraph
    case heading1, heading2, heading3
    case bulletList, numberedList, todo, toggle
    case code, callout, divider

    public var id: String { rawValue }
}

public enum CalloutStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case info, warn, tip

    public var id: String { rawValue }
}

public struct NoteBlock: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: BlockKind
    public var text: String
    public var checked: Bool
    public var collapsed: Bool
    public var children: [NoteBlock]
    public var calloutStyle: CalloutStyle
    public var language: String

    public init(
        id: UUID = UUID(),
        kind: BlockKind = .paragraph,
        text: String = "",
        checked: Bool = false,
        collapsed: Bool = false,
        children: [NoteBlock] = [],
        calloutStyle: CalloutStyle = .info,
        language: String = "swift"
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.checked = checked
        self.collapsed = collapsed
        self.children = children
        self.calloutStyle = calloutStyle
        self.language = language
    }

    public static func empty(_ kind: BlockKind = .paragraph) -> NoteBlock {
        NoteBlock(kind: kind)
    }
}

public struct NoteCategory: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var sortOrder: Int

    public init(id: UUID = UUID(), name: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}

public struct NotePageSummary: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var categoryID: UUID
    public var updatedAt: Date

    public init(id: UUID, title: String, categoryID: UUID, updatedAt: Date) {
        self.id = id
        self.title = title
        self.categoryID = categoryID
        self.updatedAt = updatedAt
    }
}

public struct NotePage: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var categoryID: UUID
    public var updatedAt: Date
    public var blocks: [NoteBlock]

    public init(
        id: UUID = UUID(),
        title: String = "",
        categoryID: UUID,
        updatedAt: Date = Date(),
        blocks: [NoteBlock] = [NoteBlock.empty()]
    ) {
        self.id = id
        self.title = title
        self.categoryID = categoryID
        self.updatedAt = updatedAt
        self.blocks = blocks
    }
}

public struct NotesIndexFile: Codable, Sendable {
    public var categories: [NoteCategory]
    public var pages: [NotePageSummary]
    public var openTabIDs: [UUID]
    public var recentPageIDs: [UUID]

    public init(
        categories: [NoteCategory] = [],
        pages: [NotePageSummary] = [],
        openTabIDs: [UUID] = [],
        recentPageIDs: [UUID] = []
    ) {
        self.categories = categories
        self.pages = pages
        self.openTabIDs = openTabIDs
        self.recentPageIDs = recentPageIDs
    }
}

public struct NotePreview: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var excerpt: String
    public var updatedAt: Date

    public init(id: UUID, title: String, excerpt: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.excerpt = excerpt
        self.updatedAt = updatedAt
    }
}

public enum NotesPaths {
    public static var root: URL {
        ConfigPaths.root.appendingPathComponent("notes", isDirectory: true)
    }

    public static var index: URL { root.appendingPathComponent("index.json") }
    public static var pagesDir: URL { root.appendingPathComponent("pages", isDirectory: true) }

    public static func pageURL(_ id: UUID) -> URL {
        pagesDir.appendingPathComponent("\(id.uuidString).json")
    }

    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
    }
}

public struct NotepadSettings: Equatable, Sendable {
    public var enabled: Bool
    public var sizeRatio: Double
    public var lengthRatio: Double
    public var animationDuration: Double
    public var inset: Double
    public var edge: QuakeEdge
    public var blur: Bool
    public var blurIntensity: Double
    public var opacity: Double
    public var defaultCategoryID: String?

    public static let `default` = NotepadSettings(
        enabled: true,
        sizeRatio: 0.55,
        lengthRatio: 1.0,
        animationDuration: 0.18,
        inset: 8,
        edge: .top,
        blur: true,
        blurIntensity: 0.7,
        opacity: 0.96,
        defaultCategoryID: nil
    )

    public init(
        enabled: Bool,
        sizeRatio: Double,
        lengthRatio: Double,
        animationDuration: Double,
        inset: Double,
        edge: QuakeEdge,
        blur: Bool,
        blurIntensity: Double,
        opacity: Double,
        defaultCategoryID: String?
    ) {
        self.enabled = enabled
        self.sizeRatio = sizeRatio
        self.lengthRatio = lengthRatio
        self.animationDuration = animationDuration
        self.inset = inset
        self.edge = edge
        self.blur = blur
        self.blurIntensity = min(1, max(0, blurIntensity))
        self.opacity = min(1, max(0.2, opacity))
        self.defaultCategoryID = defaultCategoryID
    }

    public var effectiveOpacity: Double {
        let base = min(1, max(0.2, opacity))
        if blur, base > 0.94 { return 0.92 }
        return base
    }
}
