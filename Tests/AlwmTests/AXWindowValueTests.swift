import ApplicationServices
import Testing
@testable import Alwm

@Suite("Accessibility window values")
struct AXWindowValueTests {
    @Test("Accessibility elements reject values of the wrong CF type")
    func rejectsUnexpectedElementTypes() {
        #expect(AXBridge.element("not-an-AXUIElement" as NSString) == nil)
        #expect(AXBridge.element(AXUIElementCreateSystemWide()) != nil)
    }

    @Test("invalid position or size values are rejected")
    func rejectsUnexpectedValues() {
        #expect(AXWindow.decodeFrame(positionValue: "not-an-AXValue" as NSString, sizeValue: nil) == nil)
        #expect(AXWindow.decodeFrame(positionValue: nil, sizeValue: "not-an-AXValue" as NSString) == nil)
    }

    @Test("valid position and size AXValues decode to a frame")
    func decodesFrame() {
        var point = CGPoint(x: 12, y: 34)
        var size = CGSize(width: 560, height: 420)
        let positionValue = AXValueCreate(.cgPoint, &point)!
        let sizeValue = AXValueCreate(.cgSize, &size)!

        let frame = AXWindow.decodeFrame(positionValue: positionValue, sizeValue: sizeValue)

        #expect(frame?.x == 12)
        #expect(frame?.y == 34)
        #expect(frame?.width == 560)
        #expect(frame?.height == 420)
    }

    @Test("menu-level AX windows are excluded from managed app windows")
    func excludesMenuLayerWindows() {
        #expect(AXWindow.shouldIgnoreWindowLayer(101, menuBarLevel: 24))
        #expect(!AXWindow.shouldIgnoreWindowLayer(0, menuBarLevel: 24))
        #expect(!AXWindow.shouldIgnoreWindowLayer(3, menuBarLevel: 24))
    }
}
