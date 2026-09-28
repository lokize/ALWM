import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Alwm

@Suite("Plugin monitor preferences")
struct PluginSettingsStoreTests {
    @Test("legacy all-monitor choices migrate once to the global default")
    func migratesLegacyDisplayChoicesOnlyOnce() throws {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = """
        [[plugins]]
        id = "legacy"
        enabled = true
        display = "all"
        order = 0

        [[plugins]]
        id = "fixed"
        enabled = true
        display = "1234"
        order = 1
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let store = PluginSettingsStore(url: url)

        #expect(store.state(for: "legacy").display == .default)
        #expect(store.state(for: "fixed").display == .display(1234))
        store.setDisplay(.all, for: "legacy")
        let reloaded = PluginSettingsStore(url: url)
        #expect(reloaded.state(for: "legacy").display == .all)
    }

    @Test("default monitor is saved and controls default plugin visibility")
    func persistsDefaultMonitorAndResolvesVisibility() {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PluginSettingsStore(url: url)
        store.upsert(PluginUserState(id: "sample", display: .default))
        store.setDefaultDisplayMonitorID(1234)

        let reloaded = PluginSettingsStore(url: url)
        let display = reloaded.state(for: "sample").display

        #expect(reloaded.defaultDisplayMonitorID == 1234)
        #expect(display.matches(1234, defaultMonitorID: reloaded.defaultDisplayMonitorID))
        #expect(!display.matches(5678, defaultMonitorID: reloaded.defaultDisplayMonitorID))
        #expect(PluginBarDisplay.all.matches(5678, defaultMonitorID: reloaded.defaultDisplayMonitorID))
    }

    private func temporarySettingsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-plugin-settings-\(UUID().uuidString).toml")
    }
}

@Suite("Settings scroll preservation")
struct SettingsScrollPreservationTests {
    @Test("restoring after a view replacement keeps the page position")
    @MainActor
    func restoresPositionIntoReplacementScrollView() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let oldScroll = makeScrollView()
        oldScroll.frame = window.contentView!.bounds
        window.contentView!.addSubview(oldScroll)
        oldScroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 240))
        let snapshot = FormScrollPin.capture(from: oldScroll)
        oldScroll.removeFromSuperview()
        let replacement = makeScrollView()
        replacement.frame = window.contentView!.bounds
        window.contentView!.addSubview(replacement)

        FormScrollPin.restore(snapshot)

        #expect(replacement.contentView.bounds.origin.y == 240)
    }

    @MainActor
    private func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 200))
        scroll.hasVerticalScroller = true
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 900))
        scroll.documentView = document
        return scroll
    }
}
