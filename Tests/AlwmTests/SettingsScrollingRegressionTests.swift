import AppKit
import SwiftUI
import Testing
@testable import Alwm

@Suite("Settings scrolling regression", .serialized)
struct SettingsScrollingRegressionTests {
    @Test("workspace setting edits retain the Form scroll position")
    @MainActor
    func workspaceSettingEditKeepsScroll() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(SettingsWindowController.windowIdentifier)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.hasVerticalScroller = true
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 1200))
        window.contentView?.addSubview(scroll)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 300))
        var name = "Before"
        let source = Binding<String>(
            get: { name },
            set: { value in
                name = value
                // Native Form can reset the clip while reconciling a changed row.
                scroll.contentView.setBoundsOrigin(.zero)
            }
        )

        FormScrollPin.preservingScroll(source).wrappedValue = "After"

        #expect(name == "After")
        #expect(scroll.contentView.bounds.origin.y == 300)
    }

    @Test("Plugins catalog exposes a vertically scrollable document")
    @MainActor
    func pluginsCatalogScrolls() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let items = (0..<24).map { index in
            let id = "test.plugin.\(index)"
            return SettingsPluginItem(
                id: id,
                manifest: PluginManifest(id: id, name: "Plugin \(index)", author: "Test", version: "1"),
                discovered: nil,
                isInstalled: false,
                isEnabled: false,
                isBusy: false
            )
        }
        let root = SettingsRootView(
            config: .default,
            initialPane: .plugins,
            monitors: [],
            runningAppsProvider: { [] },
            onCaptureAppRuleFrame: { _ in nil },
            onApplyRulesNow: {},
            onSave: { _ in },
            onDump: {},
            onRevealConfig: {},
            onResetRuntime: {},
            pluginsPreviewItems: items,
            onRerunOnboarding: {}
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 780),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let scrolls = scrollViews(in: window.contentView)
        let catalog = try #require(scrolls.first { scroll in
            scroll.frame.width > 400 &&
            scroll.hasVerticalScroller &&
            (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 100
        })
        #expect(catalog is OverflowAwareScrollView)
        let before = catalog.contentView.bounds.origin.y
        let cgEvent = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
            wheel1: -100, wheel2: 0, wheel3: 0
        ))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        catalog.scrollWheel(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        #expect(catalog.contentView.bounds.origin.y > before)
    }

    @MainActor
    private func scrollViews(in root: NSView?) -> [NSScrollView] {
        guard let root else { return [] }
        return ([root as? NSScrollView].compactMap { $0 }) + root.subviews.flatMap { scrollViews(in: $0) }
    }
}
