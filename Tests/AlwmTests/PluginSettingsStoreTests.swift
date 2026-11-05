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

    @Test("default monitor persists name and identity across dynamic display ID reassignment")
    func resolvesDefaultMonitorByNameAcrossDynamicDisplayIDChanges() {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PluginSettingsStore(url: url)
        store.setDefaultDisplayMonitor(
            id: 3,
            name: "MSI MAG401QR",
            identity: "display:13929:16037:msi mag401qr:2560x1080#0"
        )

        let reloaded = PluginSettingsStore(url: url)
        #expect(reloaded.defaultDisplayMonitorID == 3)
        #expect(reloaded.defaultDisplayMonitorName == "MSI MAG401QR")
        #expect(reloaded.defaultDisplayMonitorIdentity == "display:13929:16037:msi mag401qr:2560x1080#0")

        // Simulate reboot: CoreGraphics assigns ID 1 to MSI MAG401QR and ID 2 to built-in display
        let newMonitors = [
            MonitorInfo(
                id: 2,
                frame: Rect(x: 0, y: 0, width: 1440, height: 900),
                visibleFrame: Rect(x: 0, y: 0, width: 1440, height: 875),
                name: "Built-in Display",
                stableIdentity: "display:0:0:builtin#0"
            ),
            MonitorInfo(
                id: 1,
                frame: Rect(x: 1440, y: 0, width: 2560, height: 1080),
                visibleFrame: Rect(x: 1440, y: 0, width: 2560, height: 1055),
                name: "MSI MAG401QR",
                stableIdentity: "display:13929:16037:msi mag401qr:2560x1080#0"
            )
        ]

        reloaded.resolveMonitors(newMonitors)
        #expect(reloaded.defaultDisplayMonitorID == 1)
        #expect(reloaded.defaultDisplayMonitorName == "MSI MAG401QR")
    }

    @Test("reorder guarantees unique sequential order without collision")
    func reorderMaintainsCollisionFreeOrdering() {
        let url = temporarySettingsURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PluginSettingsStore(url: url)
        store.upsert(PluginUserState(id: "p1", enabled: true, order: 0))
        store.upsert(PluginUserState(id: "p2", enabled: true, order: 1))
        store.upsert(PluginUserState(id: "p3", enabled: false, order: 2))

        // Reorder enabled plugins in reverse: p2 first, then p1
        store.reorder(["p2", "p1"])

        let reloaded = PluginSettingsStore(url: url)
        #expect(reloaded.state(for: "p2").order == 0)
        #expect(reloaded.state(for: "p1").order == 1)
        #expect(reloaded.state(for: "p3").order == 2)
        #expect(reloaded.orderedIDs(catalogIDs: ["p1", "p2", "p3"]) == ["p2", "p1", "p3"])
    }

    private func temporarySettingsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("alwm-plugin-settings-\(UUID().uuidString).toml")
    }
}

@Suite("Settings scroll preservation")
struct SettingsScrollPreservationTests {
    @Test("reordering preserves both the page and the plugin list positions")
    @MainActor
    func restoresNestedPluginListPosition() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let page = makeScrollView()
        page.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        page.documentView?.frame.size.height = 1500
        let pluginList = makeScrollView()
        pluginList.frame = NSRect(x: 0, y: 0, width: 600, height: 150)
        page.documentView?.addSubview(pluginList)
        window.contentView?.addSubview(page)
        page.contentView.setBoundsOrigin(NSPoint(x: 0, y: 240))
        pluginList.contentView.setBoundsOrigin(NSPoint(x: 0, y: 120))

        let snapshot = FormScrollPin.capture(from: pluginList)
        page.contentView.setBoundsOrigin(.zero)
        pluginList.contentView.setBoundsOrigin(.zero)
        FormScrollPin.restore(snapshot)

        #expect(page.contentView.bounds.origin.y == 240)
        #expect(pluginList.contentView.bounds.origin.y == 120)
    }

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
