import Foundation

/// Discovers packaged `.alwmplugin` bundles (plus repo `plugins/` in debug).
public enum PluginCatalog {
    public static func discover() -> [DiscoveredPlugin] {
        var results: [DiscoveredPlugin] = []
        var seen = Set<String>()

        for root in searchRoots() {
            let urls = pluginBundleURLs(in: root) + pluginSourceFolders(in: root)
            for url in urls {
                guard let plugin = load(from: url), !seen.contains(plugin.id) else { continue }
                seen.insert(plugin.id)
                results.append(plugin)
            }
        }
        return results.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
    }

    public static func load(from url: URL) -> DiscoveredPlugin? {
        let fm = FileManager.default
        let isBundle = url.pathExtension == "alwmplugin" || url.pathExtension == "bundle"
        let base = isBundle ? url : url

        // Prefer Contents/Resources; fall back to bundle root (source tree).
        let resourceRoots: [URL] = [
            base.appendingPathComponent("Contents/Resources", isDirectory: true),
            base
        ]

        var manifestURL: URL?
        var resourceRoot = base
        for root in resourceRoots {
            let candidate = root.appendingPathComponent("plugin.json")
            if fm.fileExists(atPath: candidate.path) {
                manifestURL = candidate
                resourceRoot = root
                break
            }
        }
        guard let manifestURL,
              let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
        else { return nil }

        let readme = resourceRoot.appendingPathComponent("README.md")
        let preview: URL? = {
            guard let rel = manifest.preview else { return nil }
            let u = resourceRoot.appendingPathComponent(rel)
            return fm.fileExists(atPath: u.path) ? u : nil
        }()
        let shots = manifest.screenshots.compactMap { rel -> URL? in
            let u = resourceRoot.appendingPathComponent(rel)
            return fm.fileExists(atPath: u.path) ? u : nil
        }

        return DiscoveredPlugin(
            manifest: manifest,
            bundleURL: base,
            resourceRootURL: resourceRoot,
            readmeURL: fm.fileExists(atPath: readme.path) ? readme : nil,
            previewURL: preview,
            screenshotURLs: shots
        )
    }

    private static func searchRoots() -> [URL] {
        var roots: [URL] = []
        if let plugins = Bundle.main.builtInPlugInsURL {
            roots.append(plugins)
        }
        // Dev: ALWM_PLUGINS_DIR, cwd/plugins, or plugins next to the .app parent.
        if let env = ProcessInfo.processInfo.environment["ALWM_PLUGINS_DIR"] {
            roots.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        if FileManager.default.fileExists(atPath: cwd.path) {
            roots.append(cwd)
        }
        if let exe = Bundle.main.executableURL?
            .deletingLastPathComponent() // MacOS
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // .app
            .deletingLastPathComponent() // parent
        {
            let candidate = exe.appendingPathComponent("plugins", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                roots.append(candidate)
            }
        }
        return roots
    }

    private static func pluginBundleURLs(in root: URL) -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.filter { $0.pathExtension == "alwmplugin" || $0.pathExtension == "bundle" }
    }

    private static func pluginSourceFolders(in root: URL) -> [URL] {
        // Source tree folders with a top-level plugin.json.
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return items.filter { url in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return false
            }
            return FileManager.default.fileExists(atPath: url.appendingPathComponent("plugin.json").path)
        }
    }
}
