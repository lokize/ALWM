import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - Config disk writer

enum ConfigWriter {
    static func write(_ config: AlwmConfig) {
        do {
            try write(config, to: ConfigPaths.root)
        } catch {
            NSLog("ALWM could not save configuration: %@", String(describing: error))
        }
    }

    static func write(_ config: AlwmConfig, to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeSettings(config.settings, to: root.appendingPathComponent("settings.toml"))
        try writeHotkeys(config.hotkeys, to: root.appendingPathComponent("hotkeys.toml"))
        try writeGestures(config.settings.gestures.bindings, to: root.appendingPathComponent("gestures.toml"))
        try writeWorkspaces(config.workspaces, to: root.appendingPathComponent("workspaces.toml"))
        try writeRules(config.rules, to: root.appendingPathComponent("apprules.d", isDirectory: true))
    }

    /// Synchronously flush only the changed groups. The settings window uses this
    /// at the edit boundary so a later app quit cannot cancel a debounce-only save.
    static func writeChanges(from old: AlwmConfig, to new: AlwmConfig) {
        do {
            try writeChanges(from: old, to: new, at: ConfigPaths.root)
        } catch {
            NSLog("ALWM could not save changed configuration: %@", String(describing: error))
        }
    }

    static func writeChanges(from old: AlwmConfig, to new: AlwmConfig, at root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if old.settings != new.settings {
            try writeSettings(new.settings, to: root.appendingPathComponent("settings.toml"))
        }
        if old.hotkeys != new.hotkeys {
            try writeHotkeys(new.hotkeys, to: root.appendingPathComponent("hotkeys.toml"))
        }
        if old.settings.gestures.bindings != new.settings.gestures.bindings {
            try writeGestures(new.settings.gestures.bindings, to: root.appendingPathComponent("gestures.toml"))
        }
        if old.workspaces != new.workspaces {
            try writeWorkspaces(new.workspaces, to: root.appendingPathComponent("workspaces.toml"))
        }
        if old.rules != new.rules {
            try writeRules(new.rules, to: root.appendingPathComponent("apprules.d", isDirectory: true))
        }
    }

    static func writeSettings(_ settings: LayoutSettings) {
        do {
            try FileManager.default.createDirectory(at: ConfigPaths.root, withIntermediateDirectories: true)
            try writeSettings(settings, to: ConfigPaths.settings)
        } catch {
            NSLog("ALWM could not save settings.toml: %@", String(describing: error))
        }
    }

    private static func writeSettings(_ settings: LayoutSettings, to url: URL) throws {
        try settingsTOML(settings).write(to: url, atomically: true, encoding: .utf8)
    }

    static func settingsTOML(_ settings: LayoutSettings) -> String {
        let monitorDirectories = settings.wallpaper.monitorDirectories
            .sorted { $0.key < $1.key }
            .map { tomlString("\($0.key):\($0.value)") }
            .joined(separator: ", ")
        return """
        gap = \(settings.gap)
        outerGap = \(settings.outerGap)
        defaultColumnWidthRatio = \(settings.defaultColumnWidthRatio)
        minColumnWidth = \(settings.minColumnWidth)
        animationDuration = \(settings.animationDuration)
        focusFollowsMouse = \(settings.focusFollowsMouse)
        moveMouseToFocusedWindow = \(settings.moveMouseToFocusedWindow)
        warpCursorOnEmptyWorkspace = \(settings.warpCursorOnEmptyWorkspace)
        ipcEnabled = \(settings.ipcEnabled)
        developerMode = \(settings.developerMode)
        theme = "\(settings.theme.rawValue)"
        language = "\(settings.language.rawValue)"
        showMenuBarStatusLabel = \(settings.showMenuBarStatusLabel)
        preventDisplaySleep = \(settings.preventDisplaySleep)
        launchAtLogin = \(settings.launchAtLogin)
        onboardingCompleted = \(settings.onboardingCompleted)
        bordersEnabled = \(settings.borders.enabled)
        borderWidth = \(settings.borders.width)
        borderColor = "\(settings.borders.colorHex)"
        workspaceBarEnabled = \(settings.workspaceBar.enabled)
        workspaceBarHeight = \(settings.workspaceBar.height)
        workspaceBarWidthScale = \(settings.workspaceBar.widthScale)
        workspaceBarPosition = "\(settings.workspaceBar.position.rawValue)"
        workspaceBarAlignment = "\(settings.workspaceBar.alignment.rawValue)"
        workspaceBarHorizontalOffset = \(settings.workspaceBar.horizontalOffset)
        workspaceBarShowLabels = \(settings.workspaceBar.showLabels)
        workspaceBarShowAppIcons = \(settings.workspaceBar.showAppIcons)
        workspaceBarDeduplicateAppIcons = \(settings.workspaceBar.deduplicateAppIcons)
        workspaceBarShowFocusedStatus = \(settings.workspaceBar.showFocusedStatus)
        workspaceBarBackgroundOpacity = \(settings.workspaceBar.backgroundOpacity)
        workspaceBarReserveLayoutSpace = \(settings.workspaceBar.reserveLayoutSpace)
        workspaceBarSeparatePluginBadges = \(settings.workspaceBar.separatePluginBadges)
        workspaceBarPluginBadgeSpacing = \(settings.workspaceBar.pluginBadgeSpacing)
        wallpaperEnabled = \(settings.wallpaper.enabled)
        wallpaperDirectory = \(tomlString(settings.wallpaper.directory))
        wallpaperRotationEnabled = \(settings.wallpaper.rotationEnabled)
        wallpaperIntervalSeconds = \(settings.wallpaper.intervalSeconds)
        wallpaperIntervalUnit = \(tomlString(settings.wallpaper.intervalUnit.rawValue))
        wallpaperOrder = \(tomlString(settings.wallpaper.order.rawValue))
        wallpaperRecursive = \(settings.wallpaper.recursive)
        wallpaperSeparatePerMonitor = \(settings.wallpaper.separatePerMonitor)
        wallpaperMonitorDirectories = [\(monitorDirectories)]
        wallpaperVideoMuted = \(settings.wallpaper.videoMuted)
        quakeEnabled = \(settings.quake.enabled)
        quakeBundleID = "\(settings.quake.bundleID)"
        quakeSizeRatio = \(settings.quake.sizeRatio)
        quakeLengthRatio = \(settings.quake.lengthRatio)
        quakeAnimationDuration = \(settings.quake.animationDuration)
        quakeInset = \(settings.quake.inset)
        quakeEdge = "\(settings.quake.edge.rawValue)"
        quakeBlur = \(settings.quake.blur)
        quakeBlurIntensity = \(settings.quake.blurIntensity)
        quakeOpacity = \(settings.quake.opacity)
        quakeDismissOnClickOutside = \(settings.quake.dismissOnClickOutside)
        notepadEnabled = \(settings.notepad.enabled)
        notepadSizeRatio = \(settings.notepad.sizeRatio)
        notepadLengthRatio = \(settings.notepad.lengthRatio)
        notepadAnimationDuration = \(settings.notepad.animationDuration)
        notepadInset = \(settings.notepad.inset)
        notepadEdge = "\(settings.notepad.edge.rawValue)"
        notepadBlur = \(settings.notepad.blur)
        notepadBlurIntensity = \(settings.notepad.blurIntensity)
        notepadOpacity = \(settings.notepad.opacity)
        notepadDismissOnClickOutside = \(settings.notepad.dismissOnClickOutside)
        gesturesEnabled = \(settings.gestures.enabled)
        scrollSnap = \(settings.gestures.scrollSnap)
        swipeScrollFactor = \(settings.gestures.swipeScrollFactor)
        invertScroll = \(settings.gestures.invertScroll)
        """
    }

    static func tomlString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }

    static func writeHotkeys(_ hotkeys: [HotkeyBinding]) {
        do {
            try FileManager.default.createDirectory(at: ConfigPaths.root, withIntermediateDirectories: true)
            try writeHotkeys(hotkeys, to: ConfigPaths.hotkeys)
        } catch {
            NSLog("ALWM could not save hotkeys.toml: %@", String(describing: error))
        }
    }

    private static func writeHotkeys(_ hotkeys: [HotkeyBinding], to url: URL) throws {
        var lines: [String] = []
        for hk in hotkeys {
            let mods = hk.modifiers.map { "\"\($0)\"" }.joined(separator: ", ")
            lines.append("""
            [[bindings]]
            action = "\(hk.action)"
            key = "\(hk.key)"
            modifiers = [\(mods)]
            """)
        }
        try lines.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeGestures(_ bindings: [GestureBinding]) {
        do {
            try FileManager.default.createDirectory(at: ConfigPaths.root, withIntermediateDirectories: true)
            try writeGestures(bindings, to: ConfigPaths.gestures)
        } catch {
            NSLog("ALWM could not save gestures.toml: %@", String(describing: error))
        }
    }

    private static func writeGestures(_ bindings: [GestureBinding], to url: URL) throws {
        var lines: [String] = []
        for b in bindings {
            lines.append("""
            [[bindings]]
            id = "\(b.id)"
            enabled = \(b.enabled)
            fingers = \(b.fingers)
            direction = "\(b.direction.rawValue)"
            action = "\(b.action)"
            """)
        }
        try lines.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeWorkspaces(_ workspaces: [WorkspaceDefinition]) {
        do {
            try FileManager.default.createDirectory(at: ConfigPaths.root, withIntermediateDirectories: true)
            try writeWorkspaces(workspaces, to: ConfigPaths.workspaces)
        } catch {
            NSLog("ALWM could not save workspaces.toml: %@", String(describing: error))
        }
    }

    private static func writeWorkspaces(_ workspaces: [WorkspaceDefinition], to url: URL) throws {
        try workspacesTOML(workspaces).write(to: url, atomically: true, encoding: .utf8)
    }

    static func workspacesTOML(_ workspaces: [WorkspaceDefinition]) -> String {
        var lines: [String] = []
        for ws in workspaces {
            var block = """
            [[workspaces]]
            id = \(tomlString(ws.id))
            name = \(tomlString(ws.name))
            layout = "\(ws.layout.rawValue)"
            """
            if let idx = ws.monitorIndex {
                block += "\nmonitorIndex = \(idx)"
            }
            let apps = ws.sessionApps
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !apps.isEmpty {
                let listed = apps.map(tomlString).joined(separator: ", ")
                block += "\nsessionApps = [\(listed)]"
            }
            if ws.sessionQuitOthers {
                block += "\nsessionQuitOthers = true"
            }
            lines.append(block)
        }
        return lines.joined(separator: "\n\n")
    }

    static func writeRules(_ rules: [AppRule]) {
        do {
            try FileManager.default.createDirectory(at: ConfigPaths.root, withIntermediateDirectories: true)
            try writeRules(rules, to: ConfigPaths.appRulesDir)
        } catch {
            NSLog("ALWM could not save app rules: %@", String(describing: error))
        }
    }

    private static func writeRules(_ rules: [AppRule], to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let existing = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in existing where url.pathExtension == "toml" {
            try fm.removeItem(at: url)
        }
        for (index, rule) in rules.enumerated() {
            let slug = (rule.bundleID ?? rule.appName ?? "rule-\(index)")
                .replacingOccurrences(of: ".", with: "-")
                .replacingOccurrences(of: " ", with: "-")
                .lowercased()
            var lines = ["mode = \"\(rule.mode.rawValue)\""]
            if let bid = rule.bundleID { lines.insert("bundleID = \"\(bid)\"", at: 0) }
            if let name = rule.appName { lines.append("appName = \"\(name)\"") }
            if let ws = rule.workspace { lines.append("workspace = \"\(ws)\"") }
            if let idx = rule.monitorIndex { lines.append("monitorIndex = \(idx)") }
            if let w = rule.minWidth { lines.append("minWidth = \(w)") }
            if let h = rule.minHeight { lines.append("minHeight = \(h)") }
            if let w = rule.width { lines.append("width = \(w)") }
            if let h = rule.height { lines.append("height = \(h)") }
            if let x = rule.x { lines.append("x = \(x)") }
            if let y = rule.y { lines.append("y = \(y)") }
            let url = directory.appendingPathComponent("\(slug).toml")
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
