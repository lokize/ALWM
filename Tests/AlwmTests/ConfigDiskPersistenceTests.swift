import Foundation
import Testing
@testable import Alwm

@Suite("Configuration disk persistence")
struct ConfigDiskPersistenceTests {
    @Test("settings edits flush synchronously before the debounced apply")
    func changedSettingsFlushImmediately() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-config-edit-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = AlwmConfig.default
        var edited = original
        edited.settings.outerGap = 7.15
        edited.settings.focusFollowsMouse = false
        edited.settings.wallpaper.directory = "/tmp/Wallpapers"
        edited.workspaces.append(WorkspaceDefinition(id: "5", name: "Five", monitorIndex: 1))

        try ConfigWriter.writeChanges(from: original, to: edited, at: root)

        let settings = try ConfigStore.parseSettings(
            String(contentsOf: root.appendingPathComponent("settings.toml"), encoding: .utf8)
        )
        #expect(settings.outerGap == 7.15)
        #expect(!settings.focusFollowsMouse)
        #expect(settings.wallpaper.directory == "/tmp/Wallpapers")
        let workspaces = try ConfigStore.parseWorkspaces(
            String(contentsOf: root.appendingPathComponent("workspaces.toml"), encoding: .utf8)
        )
        #expect(workspaces.contains { $0.id == "5" })
    }

    @Test("all settings groups survive a complete disk save")
    func completeConfigSaveRoundTripsEveryGroup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-config-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var config = AlwmConfig.default
        config.settings.outerGap = 7.15
        config.settings.focusFollowsMouse = false
        config.settings.preventDisplaySleep = true
        config.settings.wallpaper.enabled = true
        config.settings.wallpaper.directory = "/tmp/Wallpapers"
        config.settings.wallpaper.rotationEnabled = true
        config.settings.workspaceBar.horizontalOffset = 0.2
        config.settings.gestures.bindings = [
            GestureBinding(id: "custom-gesture", fingers: 3, direction: .left, action: "workspace.prev")
        ]
        config.hotkeys = [HotkeyBinding(action: "focus.left", key: "h", modifiers: ["option"])]
        config.workspaces = [
            WorkspaceDefinition(id: "5", name: "Five", layout: .dwindle, monitorIndex: 1),
            WorkspaceDefinition(id: "6", name: "Six", layout: .niri, monitorIndex: 0)
        ]
        config.rules = [AppRule(bundleID: "com.example.Editor", mode: .float, workspace: "6", width: 1200)]

        try ConfigWriter.write(config, to: root)

        let settingsText = try String(contentsOf: root.appendingPathComponent("settings.toml"), encoding: .utf8)
        let savedSettings = try ConfigStore.parseSettings(settingsText)
        #expect(savedSettings.outerGap == 7.15)
        #expect(!savedSettings.focusFollowsMouse)
        #expect(savedSettings.preventDisplaySleep)
        #expect(savedSettings.wallpaper.enabled)
        #expect(savedSettings.wallpaper.directory == "/tmp/Wallpapers")
        #expect(savedSettings.workspaceBar.horizontalOffset == 0.2)

        let workspacesText = try String(contentsOf: root.appendingPathComponent("workspaces.toml"), encoding: .utf8)
        #expect(try ConfigStore.parseWorkspaces(workspacesText) == config.workspaces)

        let hotkeysText = try String(contentsOf: root.appendingPathComponent("hotkeys.toml"), encoding: .utf8)
        #expect(try ConfigStore.parseHotkeys(hotkeysText) == config.hotkeys)

        let gesturesText = try String(contentsOf: root.appendingPathComponent("gestures.toml"), encoding: .utf8)
        #expect(try ConfigStore.parseGestures(gesturesText) == config.settings.gestures.bindings)

        let rulesDir = root.appendingPathComponent("apprules.d", isDirectory: true)
        let ruleFiles = try FileManager.default.contentsOfDirectory(at: rulesDir, includingPropertiesForKeys: nil)
        #expect(ruleFiles.contains { $0.lastPathComponent == "com-example-editor.toml" })
        let ruleText = try String(contentsOf: rulesDir.appendingPathComponent("com-example-editor.toml"), encoding: .utf8)
        #expect(ruleText.contains("workspace = \"6\""))
        #expect(ruleText.contains("width = 1200.0"))
    }
}
