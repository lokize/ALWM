import AppKit
import CoreGraphics
import Foundation

/// Writes Ghostty Quake appearance overrides and builds window-scoped actions.
enum QuakeShellAppearance {
    private static let markerBegin = "# BEGIN ALWM_QUAKE"
    private static let markerEnd = "# END ALWM_QUAKE"
    static let ghosttyFloatOnTopScript = """
        tell application id "com.mitchellh.ghostty"
          perform action "toggle_window_float_on_top" on focused terminal of selected tab of front window
        end tell
        """

    static func shouldToggleFloatOnTop(currentLayer: Int, enable: Bool, floatingLayer: Int) -> Bool {
        enable ? currentLayer < floatingLayer : currentLayer >= floatingLayer
    }

    static var ghosttyQuakeConfigURL: URL {
        ConfigPaths.root.appendingPathComponent("ghostty-quake.conf", isDirectory: false)
    }

    static func sync(bundleID: String, settings: QuakeSettings) {
        guard bundleID == "com.mitchellh.ghostty" else { return }
        writeGhosttyQuakeConfig(settings: settings)
        ensureUserConfigIncludesQuakeFile()
    }

    static func writeGhosttyQuakeConfig(settings: QuakeSettings) {
        let contents = ghosttyQuakeConfigContents(settings: settings)
        let url = ghosttyQuakeConfigURL
        try? FileManager.default.createDirectory(at: ConfigPaths.root, withIntermediateDirectories: true)
        // Skip no-op writes — Ghostty reloads on every change and used to fight ALWM.
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == contents {
            return
        }
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }

    static func ghosttyQuakeConfigContents(settings: QuakeSettings) -> String {
        let opacity = settings.effectiveOpacity
        let blurLine: String = {
            guard settings.blur else { return "background-blur = false" }
            let radius = max(1, Int((settings.blurIntensity * 28).rounded()))
            return "background-blur = \(radius)"
        }()

        // Never put `config-file = …` here — that created a recursive include with the
        // user Ghostty config and hung Quake / Ghostty on open.
        let body = """
        \(markerBegin)
        # Managed by ALWM Quake. Do not add config-file lines to this file.
        background-opacity = \(String(format: "%.3f", opacity))
        \(blurLine)
        \(markerEnd)

        """
        return body
    }

    static func currentWindowLayer(windowID: Int) -> Int? {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]],
              let info = infos.first(where: {
                  (($0[kCGWindowNumber as String] as? NSNumber)?.intValue
                    ?? $0[kCGWindowNumber as String] as? Int) == windowID
              }),
              let currentLayer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
                ?? info[kCGWindowLayer as String] as? Int
        else { return nil }
        return currentLayer
    }

    static func floatOnTopActionScript(windowID: Int, enabled: Bool) -> String? {
        guard let currentLayer = currentWindowLayer(windowID: windowID),
              shouldToggleFloatOnTop(
                currentLayer: currentLayer,
                enable: enabled,
                floatingLayer: Int(CGWindowLevelForKey(.floatingWindow))
              ) else { return nil }

        return ghosttyFloatOnTopScript
    }

    /// One-way include: user config → ALWM quake file (never the reverse).
    private static func ensureUserConfigIncludesQuakeFile() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config.ghostty"),
            home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty/config"),
            home.appendingPathComponent(".config/ghostty/config")
        ]
        guard let userConfig = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
                ?? candidates.first
        else { return }

        let includeLine = "config-file = \(ghosttyQuakeConfigURL.path)"
        if !FileManager.default.fileExists(atPath: userConfig.path) {
            let starter = """
            \(markerBegin)
            \(includeLine)
            \(markerEnd)

            """
            try? FileManager.default.createDirectory(
                at: userConfig.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? starter.write(to: userConfig, atomically: true, encoding: .utf8)
            return
        }

        guard var existing = try? String(contentsOf: userConfig, encoding: .utf8) else { return }

        // Repair older broken setups that nested ALWM markers incorrectly.
        if existing.contains(ghosttyQuakeConfigURL.path) {
            return
        }

        let block = """

        \(markerBegin)
        \(includeLine)
        \(markerEnd)
        """
        existing = existing.trimmingCharacters(in: .whitespacesAndNewlines) + block + "\n"
        try? existing.write(to: userConfig, atomically: true, encoding: .utf8)
        NSLog("ALWM Quake: appended Ghostty include → %@", userConfig.path)
    }
}
