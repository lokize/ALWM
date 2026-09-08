import AppKit
import SwiftUI
import AlwmPluginAPI

// MARK: - Config disk writer

enum ConfigWriter {
    static func write(_ config: AlwmConfig) {
        writeSettings(config.settings)
        writeHotkeys(config.hotkeys)
        writeGestures(config.settings.gestures.bindings)
        writeWorkspaces(config.workspaces)
        writeRules(config.rules)
    }

    static func writeSettings(_ settings: LayoutSettings) {
        let text = """
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
        notepadEnabled = \(settings.notepad.enabled)
        notepadSizeRatio = \(settings.notepad.sizeRatio)
        notepadLengthRatio = \(settings.notepad.lengthRatio)
        notepadAnimationDuration = \(settings.notepad.animationDuration)
        notepadInset = \(settings.notepad.inset)
        notepadEdge = "\(settings.notepad.edge.rawValue)"
        notepadBlur = \(settings.notepad.blur)
        notepadBlurIntensity = \(settings.notepad.blurIntensity)
        notepadOpacity = \(settings.notepad.opacity)
        gesturesEnabled = \(settings.gestures.enabled)
        scrollSnap = \(settings.gestures.scrollSnap)
        swipeScrollFactor = \(settings.gestures.swipeScrollFactor)
        invertScroll = \(settings.gestures.invertScroll)
        """
        try? text.write(to: ConfigPaths.settings, atomically: true, encoding: .utf8)
    }

    static func writeHotkeys(_ hotkeys: [HotkeyBinding]) {
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
        try? lines.joined(separator: "\n\n").write(to: ConfigPaths.hotkeys, atomically: true, encoding: .utf8)
    }

    static func writeGestures(_ bindings: [GestureBinding]) {
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
        try? lines.joined(separator: "\n\n").write(to: ConfigPaths.gestures, atomically: true, encoding: .utf8)
    }

    static func writeWorkspaces(_ workspaces: [WorkspaceDefinition]) {
        var lines: [String] = []
        for ws in workspaces {
            var block = """
            [[workspaces]]
            id = "\(ws.id)"
            name = "\(ws.name)"
            layout = "\(ws.layout.rawValue)"
            """
            if let idx = ws.monitorIndex {
                block += "\nmonitorIndex = \(idx)"
            }
            lines.append(block)
        }
        try? lines.joined(separator: "\n\n").write(to: ConfigPaths.workspaces, atomically: true, encoding: .utf8)
    }

    static func writeRules(_ rules: [AppRule]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: ConfigPaths.appRulesDir, withIntermediateDirectories: true)
        if let existing = try? fm.contentsOfDirectory(at: ConfigPaths.appRulesDir, includingPropertiesForKeys: nil) {
            for url in existing where url.pathExtension == "toml" {
                try? fm.removeItem(at: url)
            }
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
            let url = ConfigPaths.appRulesDir.appendingPathComponent("\(slug).toml")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

