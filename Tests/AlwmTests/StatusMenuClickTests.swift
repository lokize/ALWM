import AppKit
import Testing
@testable import Alwm

@Suite("Status menu pointer interaction", .serialized)
struct StatusMenuClickTests {
    @Test("menu viewport never exceeds a short screen and leaves room for its edges")
    func smallScreenHeightIsCapped() {
        #expect(StatusMenuLayout.maxHeight(visibleFrameHeight: 240) == 224)
        #expect(StatusMenuLayout.maxHeight(visibleFrameHeight: 120) == 104)
    }

    @Test("menu width expands while preserving safe margins on narrow displays")
    func menuWidthAdaptsToDisplay() {
        #expect(StatusMenuLayout.width(visibleFrameWidth: 1920) == 620)
        #expect(StatusMenuLayout.width(visibleFrameWidth: 800) == 620)
        #expect(StatusMenuLayout.width(visibleFrameWidth: 400) == 368)
    }

    @Test("full-width menu actions span the content area inside the menu margins")
    func fullWidthActionUsesEntireContentArea() {
        #expect(StatusMenuLayout.contentWidth(menuWidth: 620) == 604)
        #expect(StatusMenuLayout.contentWidth(menuWidth: 400) == 384)
    }

    @Test("menu height hugs its content and only scrolls when content exceeds the screen")
    func viewportHeightHugsContent() {
        #expect(StatusMenuLayout.viewportHeight(contentHeight: 760, maximum: 1200) == 760)
        #expect(StatusMenuLayout.viewportHeight(contentHeight: 1400, maximum: 1200) == 1200)
        #expect(StatusMenuLayout.viewportHeight(contentHeight: 0, maximum: 1200) == 1200)
    }

    @Test("outside-click monitor uses the clicked location when the pointer has moved")
    @MainActor
    func outsideMonitorUsesEventLocation() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let cursor = NSEvent.mouseLocation
        let originX: CGFloat = cursor.x < 500 ? 1200 : 100
        let window = NSWindow(
            contentRect: NSRect(x: originX, y: 100, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        var received: CGPoint?
        let bridge = StatusMenuClickOutsideBridge { received = $0 }
        let token = try #require(bridge.installLocal())
        defer { NSEvent.removeMonitor(token) }
        let click = NSPoint(x: 25, y: 25)
        let expected = window.convertPoint(toScreen: click)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: click,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        NSApp.sendEvent(event)
        if let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: click,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ) {
            NSApp.sendEvent(mouseUp)
        }
        try await Task.sleep(for: .milliseconds(50))
        let point = try #require(received)
        #expect(abs(point.x - expected.x) < 1)
        #expect(abs(point.y - expected.y) < 1)
    }

}
