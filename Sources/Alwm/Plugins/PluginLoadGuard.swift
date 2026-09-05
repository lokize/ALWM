import Foundation

/// Survives a hard crash during plugin `dlopen` / `load`.
///
/// Flow: `begin(id)` → load → `end()`. If the process dies in between, the next
/// launch sees the marker, disables that plugin, and surfaces a notice.
enum PluginLoadGuard {
    private static var url: URL {
        ConfigPaths.root.appendingPathComponent("plugin-load-guard.txt")
    }

    static func begin(_ pluginID: String) {
        try? FileManager.default.createDirectory(
            at: ConfigPaths.root,
            withIntermediateDirectories: true
        )
        try? "\(pluginID)\n".write(to: url, atomically: true, encoding: .utf8)
        // Flush to disk before the risky work.
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.synchronize()
            try? handle.close()
        }
    }

    static func end() {
        try? FileManager.default.removeItem(at: url)
    }

    /// Returns the plugin id that was mid-load when the process last died, if any.
    static func consumeFailedLoad() -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: url)
        let id = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
}
