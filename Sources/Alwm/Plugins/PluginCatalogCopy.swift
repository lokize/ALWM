import Foundation
import AlwmL10n

/// Localized catalog copy (summary + README) for Settings → Plugins.
enum PluginCatalogCopy {
    static func summary(for plugin: DiscoveredPlugin) -> String {
        if let key = catalogKey(for: plugin.id, suffix: "summary"),
           let text = localized(key) {
            return text
        }
        return plugin.manifest.summary
    }

    static func readmeText(for plugin: DiscoveredPlugin, locale: String = PluginL10n.currentCode) -> String? {
        let resolved = PluginL10n.resolveCode(locale)
        let root = plugin.resourceRootURL
        let fm = FileManager.default

        if let key = catalogKey(for: plugin.id, suffix: "readme"),
           let text = localized(key) {
            return text
        }

        let l10nDir = root.appendingPathComponent("l10n", isDirectory: true)
        for code in [resolved, "en"] {
            let url = l10nDir.appendingPathComponent("\(code).md")
            guard fm.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return text
        }

        for name in ["README.\(resolved).md", "README.md"] {
            let url = root.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path),
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            return text
        }
        return nil
    }

    private static func catalogKey(for id: String, suffix: String) -> String? {
        guard let prefix = l10nPrefix(for: id) else { return nil }
        return "\(prefix).catalog.\(suffix)"
    }

    private static func l10nPrefix(for id: String) -> String? {
        switch id {
        case "dev.alwm.github": return "plugin.github"
        case "dev.alwm.steam-price-watcher": return "plugin.steam"
        case "dev.alwm.sample-clock": return "plugin.clock"
        default: return nil
        }
    }

    private static func localized(_ key: String) -> String? {
        let value = PluginL10n.t(key)
        return value == key ? nil : value
    }
}
