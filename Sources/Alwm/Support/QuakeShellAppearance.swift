import AppKit
import CoreGraphics
import Foundation

/// Writes Ghostty Quake appearance overrides. Does **not** spawn processes or touch
/// AppleScript — those paths froze ALWM when toggling Quake.
enum QuakeShellAppearance {
    private static let markerBegin = "# BEGIN ALWM_QUAKE"
    private static let markerEnd = "# END ALWM_QUAKE"
    static let floatOnTopBinding = "ctrl+alt+super+shift+f19=toggle_window_float_on_top"

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
        keybind = \(floatOnTopBinding)
        \(markerEnd)

        """
        return body
    }

    static func setGhosttyFloatOnTop(windowID: Int, pid: pid_t, enabled: Bool) {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]],
              let info = infos.first(where: {
                  (($0[kCGWindowNumber as String] as? NSNumber)?.intValue
                    ?? $0[kCGWindowNumber as String] as? Int) == windowID
              }),
              let currentLayer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
                ?? info[kCGWindowLayer as String] as? Int
        else { return }

        let floatingLayer = Int(CGWindowLevelForKey(.floatingWindow))
        guard shouldToggleFloatOnTop(
            currentLayer: currentLayer,
            enable: enabled,
            floatingLayer: floatingLayer
        ), let source = CGEventSource(stateID: .hidSystemState) else { return }

        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        let keyCode: CGKeyCode = 0x50 // F19
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = modifiers
        up.flags = modifiers
        down.postToPid(pid)
        up.postToPid(pid)
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
