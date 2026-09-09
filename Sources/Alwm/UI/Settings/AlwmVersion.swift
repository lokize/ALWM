import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - Version + Whats New catalog

enum AlwmVersion {
    /// Kept in sync by `scripts/bump-version.sh`. Prefer `installed` for UI / update checks.
    static let string = "0.8.4"
    static let ctlHint = "~/.local/bin/alwmctl"
    /// Version of the running app (Info.plist), falling back to the embedded constant.
    static var installed: String {
        if let fromBundle = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !fromBundle.isEmpty {
            return fromBundle
        }
        return string
    }
}

enum AlwmWhatsNew {
    struct Release: Codable, Equatable {
        var version: String
        var items: [String]
    }

    struct Catalog: Codable {
        var releases: [Release]
    }

    /// Legacy single-release file shape (pre multi-version history).
    struct LegacyPayload: Codable {
        var version: String
        var items: [String]
    }

    static var releases: [Release] {
        guard let url = AlwmResources.url(forResource: "whatsnew", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return fallback
        }
        if let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
           !catalog.releases.isEmpty {
            return catalog.releases.filter { !$0.items.isEmpty }
        }
        if let legacy = try? JSONDecoder().decode(LegacyPayload.self, from: data),
           !legacy.items.isEmpty {
            return [Release(version: legacy.version, items: legacy.items)]
        }
        return fallback
    }

    static var fallback: [Release] {
        [Release(version: AlwmVersion.string, items: ["See the README for the latest changes."])]
    }
}

