import AppKit
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
        settings.wallpaper.intervalUnit = .minutes
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

    @Test("wallpaper interval unit converts display values to persisted seconds")
    func intervalUnitConversion() {
        #expect(WallpaperIntervalUnit.seconds.intervalSeconds(from: 15) == 15)
        #expect(WallpaperIntervalUnit.minutes.intervalSeconds(from: 2) == 120)
        #expect(WallpaperIntervalUnit.minutes.displayValue(from: 120) == 2)
        #expect(WallpaperIntervalUnit.seconds.intervalSeconds(from: 0) == 1)
        #expect(WallpaperIntervalUnit.minutes.intervalSeconds(from: 2000) == 86400)
    }

    @Test("changing the rotation interval does not immediately advance the wallpaper")
    func intervalUpdateDoesNotAdvance() {
        var current = WallpaperSettings.default
        current.enabled = true
        current.directory = "/Wallpapers"
        var next = current
        next.intervalSeconds = 60
        next.intervalUnit = .minutes
        #expect(!WallpaperUpdatePolicy.shouldAdvance(from: current, to: next))
        next.directory = "/Other wallpapers"
        #expect(WallpaperUpdatePolicy.shouldAdvance(from: current, to: next))
    }

    @Test("older wallpaper configs keep the seconds unit by default")
    func legacyIntervalUnitDefaultsToSeconds() throws {
        let settings = try ConfigStore.parseSettings("wallpaperEnabled = true\nwallpaperIntervalSeconds = 45.0")
        #expect(settings.wallpaper.intervalSeconds == 45)
        #expect(settings.wallpaper.intervalUnit == .seconds)
    }

    @Test("wallpaper notification shows its subfolder path and filename")
    func notificationContent() {
        let url = URL(fileURLWithPath: "/Users/test/Wallpapers/Travel/beach.mov")
        let direct = WallpaperNotificationContent.make(for: url)
        #expect(direct.title == "Papel de parede alterado")
        #expect(direct.subtitle == "Travel")
        #expect(direct.body == "beach.mov")
        #expect(direct.wallpaperURL == url)

        let nested = URL(fileURLWithPath: "/Users/test/Wallpapers/Travel/Italy/beach.mov")
        let root = URL(fileURLWithPath: "/Users/test/Wallpapers", isDirectory: true)
        let nestedBadge = WallpaperNotificationContent.make(for: nested, relativeTo: root)
        #expect(nestedBadge.subtitle == "Travel/Italy")
        #expect(nestedBadge.body == "beach.mov")
        let rootFile = URL(fileURLWithPath: "/Users/test/Wallpapers/beach.mov")
        let rootBadge = WallpaperNotificationContent.make(for: rootFile, relativeTo: root)
        #expect(rootBadge.subtitle == "Wallpapers")
        #expect(rootBadge.body == "beach.mov")
    }

    @Test("workspace menu shows the primary monitor wallpaper, with a stable fallback")
    func activeWallpaperSelection() {
        let primary = WallpaperNotificationContent.make(
            for: URL(fileURLWithPath: "/wallpapers/primary.png")
        )
        let secondary = WallpaperNotificationContent.make(
            for: URL(fileURLWithPath: "/wallpapers/secondary.png")
        )
        let displays: [CGDirectDisplayID: WallpaperNotificationContent.Payload] = [
            5: secondary,
            2: primary
        ]

        #expect(WallpaperActiveSelection.preferred(from: displays, primaryDisplayID: 5) == secondary)
        #expect(WallpaperActiveSelection.preferred(from: displays, primaryDisplayID: 99) == primary)
        #expect(WallpaperActiveSelection.preferred(from: [:], primaryDisplayID: 5) == nil)
    }

    @Test("wallpaper badge is on top and does not take focus or mouse input")
    @MainActor
    func wallpaperBadgeWindowPolicy() {
        let panel = WallpaperToastController.makePanel(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
        defer { panel.close() }
        #expect(panel.level == .statusBar)
        #expect(panel.ignoresMouseEvents)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.styleMask.contains(.nonactivatingPanel))

        let frame = WallpaperToastController.frame(
            for: NSSize(width: 360, height: 100),
            in: NSRect(x: 0, y: 0, width: 1000, height: 800)
        )
        #expect(frame.maxX == 982)
        #expect(frame.maxY == 782)
    }

    @Test("wallpaper badge creates a thumbnail from the selected wallpaper")
    @MainActor
    func wallpaperBadgeThumbnail() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-wallpaper-thumb-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("badge.png")

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let png = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("Could not create the wallpaper fixture image")
            return
        }
        try png.write(to: url)

        let thumbnail = await WallpaperToastThumbnail.data(for: url)
        #expect(thumbnail != nil)
        #expect(thumbnail.flatMap(NSImage.init(data:)) != nil)
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
