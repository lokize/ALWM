import AppKit
import CoreGraphics

/// Positions floating plugin panels flush under the workspace-bar chip (Noctalia-style).
@MainActor
public enum PluginPanelAnchor {
    /// Slight overlap kills the hairline gap under the chip.
    public static let defaultGap: CGFloat = -2

    /// Last chip geometry per plugin id (hotkeys / menus without a live view).
    private static var lastByPlugin: [String: Geometry] = [:]

    /// Chip + bar geometry captured on the click path (`Sendable` for actor hops).
    public struct Geometry: Sendable {
        /// Horizontal center of the chip — panel is centered on this.
        public var chipMidX: CGFloat
        /// Bottom edge of the workspace-bar window (screen Y). Fallback only.
        public var barMinY: CGFloat
        /// Chip frame in screen coordinates — vertical glue uses `minY`.
        public var chipFrame: CGRect

        public init(chipMidX: CGFloat, barMinY: CGFloat, chipFrame: CGRect) {
            self.chipMidX = chipMidX
            self.barMinY = barMinY
            self.chipFrame = chipFrame
        }
    }

    /// Remember where a plugin chip lives so hotkeys can open flush to it.
    public static func remember(_ geometry: Geometry?, forPlugin id: String) {
        if let geometry {
            lastByPlugin[id] = geometry
        }
    }

    public static func remembered(forPlugin id: String) -> Geometry? {
        lastByPlugin[id]
    }

    /// Capture chip + enclosing bar window.
    nonisolated public static func geometry(of view: NSView?) -> Geometry? {
        guard let view, let win = view.window else { return nil }
        let chip = win.convertToScreen(view.convert(view.bounds, to: nil))
        return Geometry(
            chipMidX: chip.midX,
            barMinY: win.frame.minY,
            chipFrame: chip
        )
    }

    nonisolated public static func screenRect(of view: NSView?) -> CGRect? {
        geometry(of: view)?.chipFrame
    }

    public static func attach(
        _ window: NSWindow,
        size: NSSize,
        to geometry: Geometry?,
        gap: CGFloat = defaultGap
    ) {
        let mouse = NSEvent.mouseLocation
        let screen = screenContaining(geometry.map { CGPoint(x: $0.chipMidX, y: $0.chipFrame.midY) } ?? mouse)
            ?? NSScreen.main
        guard let screen else {
            window.setFrame(NSRect(origin: .zero, size: size), display: true)
            window.center()
            return
        }

        // Full screen — never `visibleFrame` (that sits below the menu bar and
        // creates a floating gap when the workspace bar overlays the menu bar).
        let full = screen.frame
        let geo = geometry ?? mouseGeometry(on: screen)

        // Vertical: glue to the chip bottom (pill), not the taller menu-bar strip.
        // `chipFrame.minY` is the visible bottom of the plugin chip.
        let glueY = geo.chipFrame.minY
        var y = glueY - size.height - gap
        if y < full.minY + 4 {
            // Not enough room below — open above the chip.
            y = geo.chipFrame.maxY + max(gap, 0)
        }

        // Horizontal: center on the chip. Never lead/trail-align (that reads as
        // "opened to the left/right of the plugin").
        var x = geo.chipMidX - size.width / 2
        let maxX = full.maxX - size.width - 4
        let minX = full.minX + 4
        if x > maxX { x = max(minX, maxX) }
        if x < minX { x = minX }

        y = min(max(y, full.minY + 4), full.maxY - size.height - 4)

        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    public static func attach(
        _ window: NSWindow,
        size: NSSize,
        toScreenRect rect: CGRect?,
        gap: CGFloat = defaultGap
    ) {
        let geo: Geometry?
        if let rect {
            geo = Geometry(chipMidX: rect.midX, barMinY: rect.minY, chipFrame: rect)
        } else {
            geo = nil
        }
        attach(window, size: size, to: geo, gap: gap)
    }

    public static func attach(
        _ window: NSWindow,
        size: NSSize,
        to anchor: NSView?,
        gap: CGFloat = defaultGap
    ) {
        attach(window, size: size, to: geometry(of: anchor), gap: gap)
    }

    /// Position before first show, then re-apply after AppKit presents (it may nudge).
    public static func attachBeforePresenting(
        _ window: NSWindow,
        size: NSSize,
        to geometry: Geometry?,
        gap: CGFloat = defaultGap
    ) {
        attach(window, size: size, to: geometry, gap: gap)
    }

    /// Re-apply after `makeKeyAndOrderFront` / `orderFront`.
    public static func attachAfterPresenting(
        _ window: NSWindow,
        size: NSSize,
        to geometry: Geometry?,
        gap: CGFloat = defaultGap
    ) {
        attach(window, size: size, to: geometry, gap: gap)
        DispatchQueue.main.async {
            attach(window, size: size, to: geometry, gap: gap)
        }
    }

    private static func mouseGeometry(on screen: NSScreen) -> Geometry {
        let mouse = NSEvent.mouseLocation
        let barHeight: CGFloat = 28
        let barMinY = screen.frame.maxY - barHeight
        let chip = CGRect(x: mouse.x - 12, y: barMinY + 4, width: 24, height: 20)
        return Geometry(chipMidX: chip.midX, barMinY: barMinY, chipFrame: chip)
    }

    private static func screenContaining(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}
