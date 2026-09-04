import AppKit
import Foundation

/// Writes Ghostty Quake appearance overrides. Does **not** spawn processes or touch
/// AppleScript — those paths froze ALWM when toggling Quake.
enum QuakeShellAppearance {
    private static let markerBegin = "# BEGIN ALWM_QUAKE"
    private static let markerEnd = "# END ALWM_QUAKE"

    static var ghosttyQuakeConfigURL: URL {
        ConfigPaths.root.appendingPathComponent("ghostty-quake.conf", isDirectory: false)
    }

    static func sync(bundleID: String, settings: QuakeSettings) {
        guard bundleID == "com.mitchellh.ghostty" else { return }
        writeGhosttyQuakeConfig(settings: settings)
        ensureUserConfigIncludesQuakeFile()
    }

    static func writeGhosttyQuakeConfig(settings: QuakeSettings) {
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
        let url = ghosttyQuakeConfigURL
        try? FileManager.default.createDirectory(at: ConfigPaths.root, withIntermediateDirectories: true)
        // Skip no-op writes — Ghostty reloads on every change and used to fight ALWM.
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing == body {
            return
        }
        try? body.write(to: url, atomically: true, encoding: .utf8)
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
