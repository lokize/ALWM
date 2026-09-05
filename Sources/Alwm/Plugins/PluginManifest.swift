import Foundation

/// Catalog category slug from `plugin.json` (`category`).
public enum PluginCategory: String, Sendable, CaseIterable, Identifiable, Codable {
    case system
    case media
    case integrations
    case utilities

    public var id: String { rawValue }

    public var l10nKey: String { "plugins.category.\(rawValue)" }

    public static func resolve(_ raw: String?) -> PluginCategory {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty,
              let value = PluginCategory(rawValue: raw)
        else {
            return .utilities
        }
        return value
    }
}

/// Metadata from `plugin.json`.
public struct PluginManifest: Equatable, Sendable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var author: String
    public var version: String
    public var apiVersion: Int
    public var license: String?
    public var summary: String
    public var category: String
    public var preview: String?
    public var screenshots: [String]
    public var defaultPlacement: String

    public var resolvedCategory: PluginCategory {
        PluginCategory.resolve(category)
    }

    public init(
        id: String,
        name: String,
        author: String,
        version: String,
        apiVersion: Int = 1,
        license: String? = "GPL-3.0",
        summary: String = "",
        category: String = PluginCategory.utilities.rawValue,
        preview: String? = nil,
        screenshots: [String] = [],
        defaultPlacement: String = "afterWorkspaces"
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.version = version
        self.apiVersion = apiVersion
        self.license = license
        self.summary = summary
        self.category = category
        self.preview = preview
        self.screenshots = screenshots
        self.defaultPlacement = defaultPlacement
    }

    enum CodingKeys: String, CodingKey {
        case id, name, author, version, apiVersion, license, summary, category, preview, screenshots, defaultPlacement
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? "Unknown"
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        apiVersion = try c.decodeIfPresent(Int.self, forKey: .apiVersion) ?? 1
        license = try c.decodeIfPresent(String.self, forKey: .license) ?? "GPL-3.0"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? PluginCategory.utilities.rawValue
        preview = try c.decodeIfPresent(String.self, forKey: .preview)
        screenshots = try c.decodeIfPresent([String].self, forKey: .screenshots) ?? []
        defaultPlacement = try c.decodeIfPresent(String.self, forKey: .defaultPlacement) ?? "afterWorkspaces"
    }
}

/// Plugin package found under PlugIns/.
public struct DiscoveredPlugin: Equatable, Identifiable {
    public var manifest: PluginManifest
    public var bundleURL: URL
    public var resourceRootURL: URL
    public var readmeURL: URL?
    public var previewURL: URL?
    public var screenshotURLs: [URL]

    public var id: String { manifest.id }

    public init(
        manifest: PluginManifest,
        bundleURL: URL,
        resourceRootURL: URL,
        readmeURL: URL? = nil,
        previewURL: URL? = nil,
        screenshotURLs: [URL] = []
    ) {
        self.manifest = manifest
        self.bundleURL = bundleURL
        self.resourceRootURL = resourceRootURL
        self.readmeURL = readmeURL
        self.previewURL = previewURL
        self.screenshotURLs = screenshotURLs
    }
}
