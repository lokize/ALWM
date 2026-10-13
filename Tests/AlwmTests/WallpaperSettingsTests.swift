import Foundation
import Testing
@testable import Alwm

@Suite("Wallpaper settings")
struct WallpaperSettingsTests {
    @Test("wallpaper and badge settings survive TOML round trip")
    func settingsRoundTrip() throws {
        var settings = LayoutSettings.default
        settings.workspaceBar.separatePluginBadges = true
        settings.workspaceBar.pluginBadgeSpacing = 11
        settings.wallpaper.enabled = true
        settings.wallpaper.directory = "/tmp/Pictures \"Summer\""
        settings.wallpaper.rotationEnabled = true
        settings.wallpaper.intervalSeconds = 600
        settings.wallpaper.order = .alphabetical
        settings.wallpaper.recursive = true
        settings.wallpaper.separatePerMonitor = true
        settings.wallpaper.monitorDirectories = ["1": "/tmp/Display 1", "2": "/tmp/Display 2"]
        settings.wallpaper.videoMuted = false
        let parsed = try ConfigStore.parseSettings(ConfigWriter.settingsTOML(settings))
        #expect(parsed.wallpaper == settings.wallpaper)
        #expect(parsed.workspaceBar.separatePluginBadges)
        #expect(parsed.workspaceBar.pluginBadgeSpacing == 11)
    }

    @Test("catalog filters media, respects recursion and rotates without immediate repetition")
    func catalogAndRotation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("alwm-wallpaper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for name in ["a.jpg", "b.mp4", "ignore.txt", "sub/c.png"] {
            try Data().write(to: root.appendingPathComponent(name))
        }
        let direct = WallpaperCatalog.files(in: root.path, recursive: false)
        let recursive = WallpaperCatalog.files(in: root.path, recursive: true)
        #expect(direct.map(\.lastPathComponent) == ["a.jpg", "b.mp4"])
        #expect(recursive.count == 3)
        #expect(WallpaperCatalog.next(from: direct, after: direct[0], order: .alphabetical) == direct[1])
        #expect(WallpaperCatalog.next(from: direct, after: direct[1], order: .alphabetical) == direct[0])
        #expect(WallpaperCatalog.next(from: direct, after: direct[0], order: .random) == direct[1])
    }

    @Test("monitor overrides fall back to the shared wallpaper directory")
    func monitorDirectories() {
        var settings = WallpaperSettings.default
        settings.directory = "/shared"
        settings.monitorDirectories = ["7": "/external"]
        #expect(WallpaperCatalog.directory(settings: settings, displayID: 7) == "/shared")
        settings.separatePerMonitor = true
        #expect(WallpaperCatalog.directory(settings: settings, displayID: 7) == "/external")
        #expect(WallpaperCatalog.directory(settings: settings, displayID: 8) == "/shared")
    }
}
