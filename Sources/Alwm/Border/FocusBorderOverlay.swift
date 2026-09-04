import AppKit
import Darwin
import Foundation
import QuartzCore

@MainActor
public final class FocusBorderOverlay {
    private var window: NSWindow?
    private var width: CGFloat = 3
    private var color: NSColor = NSColor(red: 0.31, green: 0.76, blue: 0.97, alpha: 1)

    public init() {}

    public func updateStyle(width: Double, hex: String) {
        self.width = CGFloat(width)
        self.color = NSColor(hex: hex) ?? self.color
        applyLayerStyle(cornerRadius: currentCornerRadius())
    }

    public func show(
        around frame: Rect,
        windowNumber: Int?,
        monitors: [Rect],
        monitorMainHeight: Double
    ) {
        let radius = Self.resolveCornerRadius(
            windowNumber: windowNumber,
            frame: frame,
            monitors: monitors
        )
        // Convert AX top-left to Cocoa bottom-left for NSWindow.
        let cocoaY = monitorMainHeight - frame.y - frame.height
        // Expand by border width so the CALayer stroke (drawn inside bounds) sits flush
        // on the outside of the real window chrome.
        let pad = width
        let rect = NSRect(
            x: frame.x - pad,
            y: cocoaY - pad,
            width: frame.width + pad * 2,
            height: frame.height + pad * 2
        )
        if window == nil {
            let w = NSWindow(
                contentRect: rect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .floating
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .transient]
            let view = NSView(frame: NSRect(origin: .zero, size: rect.size))
            view.wantsLayer = true
            w.contentView = view
            w.orderFrontRegardless()
            window = w
        } else {
            window?.setFrame(rect, display: true)
            window?.contentView?.frame = NSRect(origin: .zero, size: rect.size)
            window?.orderFrontRegardless()
        }
        // Outer radius = chrome radius + stroke so the inner curve matches the window.
        applyLayerStyle(cornerRadius: radius > 0 ? radius + pad : 0)
    }

    public func hide() {
        window?.orderOut(nil)
    }

    private func currentCornerRadius() -> CGFloat {
        CGFloat(window?.contentView?.layer?.cornerRadius ?? 0)
    }

    private func applyLayerStyle(cornerRadius: CGFloat) {
        guard let layer = window?.contentView?.layer else { return }
        layer.borderWidth = width
        layer.borderColor = color.cgColor
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
    }

    /// Prefer the real window chrome radius; fall back to system defaults.
    static func resolveCornerRadius(
        windowNumber: Int?,
        frame: Rect,
        monitors: [Rect]
    ) -> CGFloat {
        if isEffectivelyFullscreen(frame: frame, monitors: monitors) {
            return 0
        }
        if let number = windowNumber,
           let live = WindowChromeRadius.lookup(cgWindowID: CGWindowID(number)),
           live >= 0 {
            return live
        }
        return systemStandardWindowRadius
    }

    private static var systemStandardWindowRadius: CGFloat {
        // Matches typical AppKit continuous corners for titled windows.
        if #available(macOS 15.0, *) { return 16 }
        if #available(macOS 11.0, *) { return 10 }
        return 0
    }

    private static func isEffectivelyFullscreen(frame: Rect, monitors: [Rect]) -> Bool {
        for mon in monitors {
            let dx = abs(frame.x - mon.x)
            let dy = abs(frame.y - mon.y)
            let dw = abs(frame.width - mon.width)
            let dh = abs(frame.height - mon.height)
            if dx < 2, dy < 2, dw < 4, dh < 4 {
                return true
            }
        }
        return false
    }
}

/// Best-effort read of a CGWindow's corner radius via SkyLight (optional private API).
enum WindowChromeRadius {
    static func lookup(cgWindowID: CGWindowID) -> CGFloat? {
        guard cgWindowID != 0 else { return nil }
        // SkyLight symbols differ by OS; probe a few known names without hard-linking.
        typealias Getter = @convention(c) (UInt32, CGWindowID, UnsafeMutablePointer<CGFloat>) -> Int32
        let names = [
            "SLSWindowGetCornerRadius",
            "CGSGetWindowCornerRadius",
            "CGSWindowGetCornerRadius"
        ]
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else { return nil }
        defer { dlclose(handle) }

        typealias ConnFn = @convention(c) () -> UInt32
        let conn: UInt32
        if let sym = dlsym(handle, "SLSMainConnectionID") ?? dlsym(handle, "CGSMainConnectionID") {
            conn = unsafeBitCast(sym, to: ConnFn.self)()
        } else {
            return nil
        }

        for name in names {
            guard let sym = dlsym(handle, name) else { continue }
            let fn = unsafeBitCast(sym, to: Getter.self)
            var radius: CGFloat = 0
            let status = fn(conn, cgWindowID, &radius)
            if status == 0, radius >= 0, radius < 64 {
                return radius
            }
        }
        return nil
    }
}

public extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(calibratedRed: r, green: g, blue: b, alpha: 1)
    }
}
