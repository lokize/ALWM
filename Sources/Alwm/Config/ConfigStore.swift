import Foundation
import TOML

public enum ConfigPaths {
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/alwm", isDirectory: true)
    }

    public static var settings: URL { root.appendingPathComponent("settings.toml") }
    public static var hotkeys: URL { root.appendingPathComponent("hotkeys.toml") }
    public static var gestures: URL { root.appendingPathComponent("gestures.toml") }
    public static var workspaces: URL { root.appendingPathComponent("workspaces.toml") }
    public static var appRulesDir: URL { root.appendingPathComponent("apprules.d", isDirectory: true) }
    public static var runtimeState: URL { root.appendingPathComponent("runtime-state.json") }
    public static var moveLog: URL { root.appendingPathComponent("move.log") }
}

public final class ConfigStore: @unchecked Sendable {
    public private(set) var config: AlwmConfig
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private var reloadWorkItem: DispatchWorkItem?
    /// Fingerprint of settings/hotkeys/gestures/workspaces/apprules only — ignores notes,
    /// runtime-state, ghostty-quake.conf, and other sidecar writes under `~/.config/alwm/`.
    private var lastWatchedSignature: String = ""
    public var onChange: ((AlwmConfig) -> Void)?

    public init(config: AlwmConfig = .default) {
        self.config = config
    }

    public func ensureDefaultsOnDisk() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: ConfigPaths.root, withIntermediateDirectories: true)
        try fm.createDirectory(at: ConfigPaths.appRulesDir, withIntermediateDirectories: true)

        if !fm.fileExists(atPath: ConfigPaths.settings.path) {
            try Self.defaultSettingsTOML.write(to: ConfigPaths.settings, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: ConfigPaths.hotkeys.path) {
            try Self.defaultHotkeysTOML.write(to: ConfigPaths.hotkeys, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: ConfigPaths.gestures.path) {
            try Self.defaultGesturesTOML.write(to: ConfigPaths.gestures, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: ConfigPaths.workspaces.path) {
            try Self.defaultWorkspacesTOML.write(to: ConfigPaths.workspaces, atomically: true, encoding: .utf8)
        }
        let sample = ConfigPaths.appRulesDir.appendingPathComponent("float-system.toml.sample")
        if !fm.fileExists(atPath: sample.path) {
            try Self.sampleRuleTOML.write(to: sample, atomically: true, encoding: .utf8)
        }
        let ghostty = ConfigPaths.appRulesDir.appendingPathComponent("ghostty-quick-terminal.toml.sample")
        if !fm.fileExists(atPath: ghostty.path) {
            try Self.ghosttySampleTOML.write(to: ghostty, atomically: true, encoding: .utf8)
        }
    }

    public func load() throws {
        try ensureDefaultsOnDisk()
        var next = AlwmConfig.default
        if let settingsText = try? String(contentsOf: ConfigPaths.settings, encoding: .utf8) {
            next.settings = try Self.parseSettings(settingsText)
        }
        if let hotkeysText = try? String(contentsOf: ConfigPaths.hotkeys, encoding: .utf8) {
            let parsed = try Self.parseHotkeys(hotkeysText)
            let merged = Self.mergeHotkeys(parsed)
            next.hotkeys = merged
            if merged.count != parsed.count {
                ConfigWriter.writeHotkeys(merged)
            }
        }
        if let gesturesText = try? String(contentsOf: ConfigPaths.gestures, encoding: .utf8) {
            let parsed = try Self.parseGestures(gesturesText)
            var normalized = GestureBinding.deduplicated(parsed.isEmpty ? GestureBinding.default : parsed)
            // Ensure new default continuous bindings exist for older gestures.toml files.
            for fresh in GestureBinding.default where fresh.enabled {
                let exists = normalized.contains {
                    $0.fingers == fresh.fingers && $0.direction == fresh.direction
                }
                if !exists {
                    normalized.append(fresh)
                }
            }
            normalized = GestureBinding.deduplicated(normalized)
            next.settings.gestures.bindings = normalized
            // Persist cleanup so Settings does not keep showing disabled twins.
            if normalized != parsed {
                ConfigWriter.writeGestures(normalized)
            }
        } else {
            next.settings.gestures.bindings = GestureBinding.default
            try? ConfigStore.defaultGesturesTOML.write(to: ConfigPaths.gestures, atomically: true, encoding: .utf8)
        }
        if let wsText = try? String(contentsOf: ConfigPaths.workspaces, encoding: .utf8) {
            next.workspaces = try Self.parseWorkspaces(wsText)
        }
        next.rules = try Self.loadRules(from: ConfigPaths.appRulesDir)
        let syncedHotkeys = Self.syncWorkspaceHotkeys(workspaces: next.workspaces, hotkeys: next.hotkeys)
        if syncedHotkeys.count != next.hotkeys.count {
            next.hotkeys = syncedHotkeys
            ConfigWriter.writeHotkeys(syncedHotkeys)
        }
        self.config = next
    }

    public func replaceConfig(_ config: AlwmConfig) {
        self.config = config
        // Settings UI / programmatic saves write under the watched tree — refresh so
        // the subsequent FS event does not bounce applyConfig a second time.
        lastWatchedSignature = Self.watchedConfigSignature()
    }

    public func startWatching() {
        stopWatching()
        let path = ConfigPaths.root.path
        directoryFD = open(path, O_EVTONLY)
        guard directoryFD >= 0 else { return }
        lastWatchedSignature = Self.watchedConfigSignature()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.reloadWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let signature = Self.watchedConfigSignature()
                // Notes, Quake Ghostty overrides, and runtime-state live under the same
                // directory — reloading on those writes re-entered applyConfig and froze
                // ALWM + WindowServer when Quake/Notepad were open.
                guard signature != self.lastWatchedSignature else { return }
                try? self.load()
                // `load()` may normalize and rewrite hotkeys/gestures — refresh baseline.
                self.lastWatchedSignature = Self.watchedConfigSignature()
                self.onChange?(self.config)
            }
            self.reloadWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.directoryFD, fd >= 0 { close(fd) }
            self?.directoryFD = -1
        }
        self.source = source
        source.resume()
    }

    public func stopWatching() {
        reloadWorkItem?.cancel()
        reloadWorkItem = nil
        source?.cancel()
        source = nil
    }

    /// mtime+size fingerprint for files that actually define `AlwmConfig`.
    private static func watchedConfigSignature() -> String {
        var parts: [String] = []
        let roots = [
            ConfigPaths.settings,
            ConfigPaths.hotkeys,
            ConfigPaths.gestures,
            ConfigPaths.workspaces,
            ConfigPaths.root.appendingPathComponent("plugins.toml")
        ]
        for url in roots {
            parts.append(fileFingerprint(url))
        }
        let fm = FileManager.default
        if let kids = try? fm.contentsOfDirectory(
            at: ConfigPaths.appRulesDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in kids.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = url.lastPathComponent
                guard name.hasSuffix(".toml"), !name.hasSuffix(".toml.sample") else { continue }
                parts.append(fileFingerprint(url))
            }
        }
        return parts.joined(separator: "|")
    }

    private static func fileFingerprint(_ url: URL) -> String {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let date = values.contentModificationDate
        else {
            return "\(url.lastPathComponent):missing"
        }
        let size = values.fileSize ?? 0
        return "\(url.lastPathComponent):\(Int(date.timeIntervalSince1970 * 1000)):\(size)"
    }

    deinit { stopWatching() }

    public static func parseSettings(_ text: String) throws -> LayoutSettings {
        let table = try TOMLDecoder().decode(SettingsFile.self, from: text)
        var s = LayoutSettings.default
        if let v = table.gap { s.gap = v }
        if let v = table.outerGap { s.outerGap = v }
        if let v = table.defaultColumnWidthRatio { s.defaultColumnWidthRatio = v }
        if let v = table.minColumnWidth { s.minColumnWidth = v }
        if let v = table.animationDuration { s.animationDuration = v }
        if let v = table.focusFollowsMouse { s.focusFollowsMouse = v }
        if let v = table.moveMouseToFocusedWindow { s.moveMouseToFocusedWindow = v }
        if let v = table.warpCursorOnEmptyWorkspace { s.warpCursorOnEmptyWorkspace = v }
        if let v = table.ipcEnabled { s.ipcEnabled = v }
        if let v = table.developerMode { s.developerMode = v }
        if let v = table.theme, let theme = AppTheme(rawValue: v) { s.theme = theme }
        if let v = table.language, let lang = AppLanguage(rawValue: v) { s.language = lang }
        if let v = table.showMenuBarStatusLabel { s.showMenuBarStatusLabel = v }
        if let v = table.preventDisplaySleep { s.preventDisplaySleep = v }
        if let v = table.launchAtLogin { s.launchAtLogin = v }
        if let v = table.onboardingCompleted { s.onboardingCompleted = v }

        if let v = table.bordersEnabled { s.borders.enabled = v }
        if let v = table.borderWidth { s.borders.width = v }
        if let v = table.borderColor { s.borders.colorHex = v }
        if let v = table.borderCornerRadius { s.borders.cornerRadius = v }

        if let v = table.workspaceBarEnabled { s.workspaceBar.enabled = v }
        if let v = table.barHeight { s.workspaceBar.height = v }
        if let v = table.workspaceBarHeight { s.workspaceBar.height = v }
        if let v = table.workspaceBarWidthScale { s.workspaceBar.widthScale = v }
        if let v = table.workspaceBarPosition,
           let pos = WorkspaceBarPosition(rawValue: v) {
            s.workspaceBar.position = pos
        }
        if let v = table.workspaceBarAlignment,
           let align = WorkspaceBarAlignment(rawValue: v) {
            s.workspaceBar.alignment = align
        } else {
            // Older configs without alignment: dock left so the document title stays visible.
            s.workspaceBar.alignment = .left
            if table.workspaceBarPosition == nil || table.workspaceBarPosition == "belowMenuBar" {
                s.workspaceBar.position = .overlayMenuBar
                s.workspaceBar.reserveLayoutSpace = false
                if s.workspaceBar.height > 26 { s.workspaceBar.height = 24 }
            }
        }
        if let v = table.workspaceBarHorizontalOffset { s.workspaceBar.horizontalOffset = v }
        if let v = table.workspaceBarShowLabels { s.workspaceBar.showLabels = v }
        if let v = table.workspaceBarShowAppIcons { s.workspaceBar.showAppIcons = v }
        if let v = table.workspaceBarDeduplicateAppIcons { s.workspaceBar.deduplicateAppIcons = v }
        if let v = table.workspaceBarShowFocusedStatus { s.workspaceBar.showFocusedStatus = v }
        if let v = table.workspaceBarBackgroundOpacity { s.workspaceBar.backgroundOpacity = v }
        if let v = table.workspaceBarReserveLayoutSpace { s.workspaceBar.reserveLayoutSpace = v }

        if let v = table.quakeEnabled { s.quake.enabled = v }
        if let v = table.quakeBundleID { s.quake.bundleID = v }
        if let v = table.quakeHeightRatio { s.quake.sizeRatio = v }
        if let v = table.quakeSizeRatio { s.quake.sizeRatio = v }
        if let v = table.quakeLengthRatio { s.quake.lengthRatio = v }
        if let v = table.quakeAnimationDuration { s.quake.animationDuration = v }
        if let v = table.quakeWidthInset { s.quake.inset = v }
        if let v = table.quakeInset { s.quake.inset = v }
        if let v = table.quakeEdge, let edge = QuakeEdge(rawValue: v) { s.quake.edge = edge }
        if let v = table.quakeBlur { s.quake.blur = v }
        if let v = table.quakeBlurIntensity { s.quake.blurIntensity = min(1, max(0, v)) }
        if let v = table.quakeOpacity { s.quake.opacity = min(1, max(0.2, v)) }

        if let v = table.notepadEnabled { s.notepad.enabled = v }
        if let v = table.notepadSizeRatio { s.notepad.sizeRatio = v }
        if let v = table.notepadLengthRatio { s.notepad.lengthRatio = v }
        if let v = table.notepadAnimationDuration { s.notepad.animationDuration = v }
        if let v = table.notepadInset { s.notepad.inset = v }
        if let v = table.notepadEdge, let edge = QuakeEdge(rawValue: v) { s.notepad.edge = edge }
        if let v = table.notepadBlur { s.notepad.blur = v }
        if let v = table.notepadBlurIntensity { s.notepad.blurIntensity = min(1, max(0, v)) }
        if let v = table.notepadOpacity { s.notepad.opacity = min(1, max(0.2, v)) }
        if let v = table.notepadDefaultCategoryID { s.notepad.defaultCategoryID = v }

        if let v = table.gesturesEnabled { s.gestures.enabled = v }
        if let v = table.scrollSnap { s.gestures.scrollSnap = v }
        if let v = table.swipeScrollFactor { s.gestures.swipeScrollFactor = v }
        if let v = table.invertScroll { s.gestures.invertScroll = v }
        return s
    }

    public static func parseHotkeys(_ text: String) throws -> [HotkeyBinding] {
        let file = try TOMLDecoder().decode(HotkeysFile.self, from: text)
        return file.bindings.map {
            HotkeyBinding(action: $0.action, key: $0.key, modifiers: $0.modifiers)
        }
    }

    /// Adds default bindings for actions missing from older hotkeys.toml files.
    static func mergeHotkeys(_ parsed: [HotkeyBinding]) -> [HotkeyBinding] {
        var merged = parsed
        let existingActions = Set(parsed.map(\.action))
        for defaultBinding in AlwmConfig.defaultHotkeys where !existingActions.contains(defaultBinding.action) {
            merged.append(defaultBinding)
        }
        return merged
    }

    /// Ensures every configured workspace has switch/send hotkey actions (⌥N / ⌥⇧N when id is one key).
    public static func syncWorkspaceHotkeys(
        workspaces: [WorkspaceDefinition],
        hotkeys: [HotkeyBinding]
    ) -> [HotkeyBinding] {
        var merged = hotkeys
        var existingActions = Set(merged.map(\.action))
        for ws in workspaces {
            let switchAction = "workspace.\(ws.id)"
            if !existingActions.contains(switchAction),
               let key = AlwmConfig.workspaceHotkeyKey(forID: ws.id) {
                merged.append(HotkeyBinding(action: switchAction, key: key, modifiers: ["option"]))
                existingActions.insert(switchAction)
            }
            let moveAction = "move.to.workspace.\(ws.id)"
            if !existingActions.contains(moveAction),
               let key = AlwmConfig.workspaceHotkeyKey(forID: ws.id) {
                merged.append(HotkeyBinding(action: moveAction, key: key, modifiers: ["option", "shift"]))
                existingActions.insert(moveAction)
            }
        }
        return merged
    }

    static func workspaceHotkeysTOML(upTo max: Int = AlwmConfig.defaultWorkspaceHotkeyCount) -> String {
        (1...max).flatMap { n -> [String] in
            guard let key = AlwmConfig.workspaceHotkeyKey(number: n) else { return [] }
            let id = String(n)
            return [
                """
                [[bindings]]
                action = "workspace.\(id)"
                key = "\(key)"
                modifiers = ["option"]
                """,
                """
                [[bindings]]
                action = "move.to.workspace.\(id)"
                key = "\(key)"
                modifiers = ["option", "shift"]
                """,
            ]
        }
        .joined(separator: "\n\n")
    }

    public static func parseGestures(_ text: String) throws -> [GestureBinding] {
        let file = try TOMLDecoder().decode(GesturesFile.self, from: text)
        return file.bindings.map {
            GestureBinding(
                id: $0.id ?? UUID().uuidString,
                enabled: $0.enabled ?? true,
                fingers: $0.fingers ?? 2,
                direction: GestureDirection(rawValue: $0.direction ?? "horizontal") ?? .horizontal,
                action: $0.action
            )
        }
    }

    public static func parseWorkspaces(_ text: String) throws -> [WorkspaceDefinition] {
        let file = try TOMLDecoder().decode(WorkspacesFile.self, from: text)
        return file.workspaces.map {
            WorkspaceDefinition(
                id: $0.id,
                name: $0.name,
                layout: WorkspaceLayoutStyle(rawValue: $0.layout ?? "niri") ?? .niri,
                monitorIndex: $0.monitorIndex
            )
        }
    }

    public static func loadRules(from dir: URL) throws -> [AppRule] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return AlwmConfig.default.rules
        }
        var rules: [AppRule] = []
        for url in files where url.pathExtension == "toml" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let file = try TOMLDecoder().decode(AppRuleFile.self, from: text)
            let mode = AppRuleMode(rawValue: file.mode ?? "tile") ?? .tile
            rules.append(
                AppRule(
                    bundleID: file.bundleID,
                    appName: file.appName,
                    mode: mode,
                    workspace: file.workspace,
                    monitorIndex: file.monitorIndex,
                    minWidth: file.minWidth,
                    minHeight: file.minHeight,
                    width: file.width,
                    height: file.height,
                    x: file.x,
                    y: file.y
                )
            )
        }
        if rules.isEmpty { return AlwmConfig.default.rules }
        return rules
    }

    private struct SettingsFile: Decodable {
        var gap: Double?
        var outerGap: Double?
        var defaultColumnWidthRatio: Double?
        var minColumnWidth: Double?
        var barHeight: Double?
        var animationDuration: Double?
        var focusFollowsMouse: Bool?
        var moveMouseToFocusedWindow: Bool?
        var warpCursorOnEmptyWorkspace: Bool?
        var ipcEnabled: Bool?
        var developerMode: Bool?
        var theme: String?
        var language: String?
        var showMenuBarStatusLabel: Bool?
        var preventDisplaySleep: Bool?
        var launchAtLogin: Bool?
        var onboardingCompleted: Bool?
        var bordersEnabled: Bool?
        var borderWidth: Double?
        var borderColor: String?
        var borderCornerRadius: Double?
        var workspaceBarEnabled: Bool?
        var workspaceBarHeight: Double?
        var workspaceBarWidthScale: Double?
        var workspaceBarPosition: String?
        var workspaceBarAlignment: String?
        var workspaceBarHorizontalOffset: Double?
        var workspaceBarShowLabels: Bool?
        var workspaceBarShowAppIcons: Bool?
        var workspaceBarDeduplicateAppIcons: Bool?
        var workspaceBarShowFocusedStatus: Bool?
        var workspaceBarBackgroundOpacity: Double?
        var workspaceBarReserveLayoutSpace: Bool?
        var quakeEnabled: Bool?
        var quakeBundleID: String?
        var quakeHeightRatio: Double?
        var quakeSizeRatio: Double?
        var quakeLengthRatio: Double?
        var quakeAnimationDuration: Double?
        var quakeWidthInset: Double?
        var quakeInset: Double?
        var quakeEdge: String?
        var quakeBlur: Bool?
        var quakeBlurIntensity: Double?
        var quakeOpacity: Double?
        var notepadEnabled: Bool?
        var notepadSizeRatio: Double?
        var notepadLengthRatio: Double?
        var notepadAnimationDuration: Double?
        var notepadInset: Double?
        var notepadEdge: String?
        var notepadBlur: Bool?
        var notepadBlurIntensity: Double?
        var notepadOpacity: Double?
        var notepadDefaultCategoryID: String?
        var gesturesEnabled: Bool?
        var scrollSnap: Bool?
        var swipeScrollFactor: Double?
        var invertScroll: Bool?
    }

    private struct HotkeysFile: Decodable {
        struct Binding: Decodable {
            var action: String
            var key: String
            var modifiers: [String]
        }
        var bindings: [Binding]
    }

    private struct GesturesFile: Decodable {
        struct Binding: Decodable {
            var id: String?
            var enabled: Bool?
            var fingers: Int?
            var direction: String?
            var action: String
        }
        var bindings: [Binding]
    }

    private struct WorkspacesFile: Decodable {
        struct Item: Decodable {
            var id: String
            var name: String
            var layout: String?
            var monitorIndex: Int?
        }
        var workspaces: [Item]
    }

    private struct AppRuleFile: Decodable {
        var bundleID: String?
        var appName: String?
        var mode: String?
        var workspace: String?
        var monitorIndex: Int?
        var minWidth: Double?
        var minHeight: Double?
        var width: Double?
        var height: Double?
        var x: Double?
        var y: Double?
    }

    public static let defaultSettingsTOML = """
    gap = 8.0
    outerGap = 0.0
    defaultColumnWidthRatio = 0.5
    minColumnWidth = 320.0
    animationDuration = 0.18
    focusFollowsMouse = false
    moveMouseToFocusedWindow = false
    warpCursorOnEmptyWorkspace = true
    ipcEnabled = true
    developerMode = false
    theme = "system"
    language = "system"
    showMenuBarStatusLabel = true
    preventDisplaySleep = false
    launchAtLogin = true
    onboardingCompleted = false
    bordersEnabled = true
    borderWidth = 3.0
    borderColor = "#4FC3F7"
    workspaceBarEnabled = true
    workspaceBarHeight = 24.0
    workspaceBarWidthScale = 1.0
    workspaceBarPosition = "overlayMenuBar"
    workspaceBarAlignment = "left"
    workspaceBarHorizontalOffset = 0.0
    workspaceBarShowLabels = true
    workspaceBarShowAppIcons = true
    workspaceBarDeduplicateAppIcons = true
    workspaceBarShowFocusedStatus = false
    workspaceBarBackgroundOpacity = 0.0
    workspaceBarReserveLayoutSpace = false
    quakeEnabled = true
    quakeBundleID = ""
    quakeSizeRatio = 0.4
    quakeLengthRatio = 1.0
    quakeAnimationDuration = 0.16
    quakeInset = 8.0
    quakeEdge = "top"
    quakeBlur = false
    quakeBlurIntensity = 0.7
    quakeOpacity = 0.92
    notepadEnabled = true
    notepadSizeRatio = 0.55
    notepadLengthRatio = 1.0
    notepadAnimationDuration = 0.18
    notepadInset = 8.0
    notepadEdge = "top"
    notepadBlur = true
    notepadBlurIntensity = 0.7
    notepadOpacity = 0.96
    gesturesEnabled = true
    scrollSnap = true
    swipeScrollFactor = 2.2
    invertScroll = false
    """

    public static let defaultHotkeysTOML: String = """
    [[bindings]]
    action = "focus.left"
    key = "left"
    modifiers = ["option"]

    [[bindings]]
    action = "focus.right"
    key = "right"
    modifiers = ["option"]

    [[bindings]]
    action = "focus.up"
    key = "up"
    modifiers = ["option"]

    [[bindings]]
    action = "focus.down"
    key = "down"
    modifiers = ["option"]

    [[bindings]]
    action = "focus.left"
    key = "h"
    modifiers = ["option"]

    [[bindings]]
    action = "focus.right"
    key = "l"
    modifiers = ["option"]

    [[bindings]]
    action = "focus.up"
    key = "k"
    modifiers = ["option"]

    [[bindings]]
    action = "focus.down"
    key = "j"
    modifiers = ["option"]

    [[bindings]]
    action = "move.left"
    key = "left"
    modifiers = ["option", "shift"]

    [[bindings]]
    action = "move.right"
    key = "right"
    modifiers = ["option", "shift"]

    [[bindings]]
    action = "move.up"
    key = "up"
    modifiers = ["option", "shift"]

    [[bindings]]
    action = "move.down"
    key = "down"
    modifiers = ["option", "shift"]

    """ + workspaceHotkeysTOML() + """

    [[bindings]]
    action = "resize.left"
    key = "-"
    modifiers = ["option"]

    [[bindings]]
    action = "resize.right"
    key = "="
    modifiers = ["option"]

    [[bindings]]
    action = "resize.up"
    key = "-"
    modifiers = ["option", "shift"]

    [[bindings]]
    action = "resize.down"
    key = "="
    modifiers = ["option", "shift"]

    [[bindings]]
    action = "scroll.left"
    key = "u"
    modifiers = ["option"]

    [[bindings]]
    action = "scroll.right"
    key = "i"
    modifiers = ["option"]

    [[bindings]]
    action = "quake.toggle"
    key = "t"
    modifiers = ["option"]

    [[bindings]]
    action = "notepad.toggle"
    key = "n"
    modifiers = ["option"]

    [[bindings]]
    action = "notepad.new"
    key = "n"
    modifiers = ["option", "shift"]

    [[bindings]]
    action = "palette.toggle"
    key = "p"
    modifiers = ["option"]

    [[bindings]]
    action = "capture.region"
    key = "4"
    modifiers = ["control", "command", "shift"]

    [[bindings]]
    action = "capture.display"
    key = "3"
    modifiers = ["control", "command", "shift"]

    [[bindings]]
    action = "capture.record.toggle"
    key = "5"
    modifiers = ["control", "command", "shift"]

    [[bindings]]
    action = "float.toggle"
    key = "f"
    modifiers = ["option"]

    [[bindings]]
    action = "column.maximize"
    key = "f"
    modifiers = ["option", "shift"]

    [[bindings]]
    action = "settings.open"
    key = ","
    modifiers = ["option"]
    """

    public static let defaultGesturesTOML = """
    [[bindings]]
    id = "3-horizontal-scroll"
    enabled = true
    fingers = 3
    direction = "horizontal"
    action = "scroll.columns"

    [[bindings]]
    id = "3-vertical-stack"
    enabled = true
    fingers = 3
    direction = "vertical"
    action = "scroll.stack"

    [[bindings]]
    id = "4-left-workspace-prev"
    enabled = true
    fingers = 4
    direction = "left"
    action = "workspace.prev"

    [[bindings]]
    id = "4-right-workspace-next"
    enabled = true
    fingers = 4
    direction = "right"
    action = "workspace.next"
    """

    public static let defaultWorkspacesTOML = """
    [[workspaces]]
    id = "1"
    name = "1"
    layout = "niri"
    monitorIndex = 0

    [[workspaces]]
    id = "2"
    name = "2"
    layout = "niri"
    monitorIndex = 0

    [[workspaces]]
    id = "3"
    name = "3"
    layout = "dwindle"
    monitorIndex = 0

    [[workspaces]]
    id = "4"
    name = "4"
    layout = "niri"
    monitorIndex = 1
    """

    public static let sampleRuleTOML = """
    bundleID = "com.apple.systempreferences"
    mode = "float"
    """

    public static let ghosttySampleTOML = """
    # Rename to .toml to activate.
    bundleID = "com.mitchellh.ghostty"
    mode = "ignore"
    """
}
