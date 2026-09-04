import Foundation

/// Helpers for parking windows far enough that side-by-side monitors do not show them.
public enum OffscreenParking {
    public static func parkOrigin(monitors: [Rect], preferred: Rect?) -> (x: Double, y: Double) {
        let union = monitors.reduce(preferred ?? Rect(x: 0, y: 0, width: 1, height: 1)) { acc, m in
            let minX = min(acc.x, m.x)
            let minY = min(acc.y, m.y)
            let maxX = max(acc.maxX, m.maxX)
            let maxY = max(acc.maxY, m.maxY)
            return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        // Park BELOW the arrangement (not to the left). macOS often clamps
        // left-parked windows into a visible strip on the leading edge.
        return (
            union.midX - 40,
            union.maxY + max(union.height, 2500) + 1200
        )
    }

    /// Off-screen rect that keeps a usable size (never collapse to 1×1).
    public static func parkedFrame(
        origin: (x: Double, y: Double),
        sizeFrom: Rect,
        live: Rect
    ) -> Rect {
        let width = preferredParkSize(sizeFrom.width, live.width, fallback: 800)
        let height = preferredParkSize(sizeFrom.height, live.height, fallback: 600)
        return Rect(x: origin.x, y: origin.y, width: width, height: height)
    }

    private static func preferredParkSize(_ a: Double, _ b: Double, fallback: Double) -> Double {
        if a > 48 { return a }
        if b > 48 { return b }
        return fallback
    }

    /// True when the window's center lies on a monitor (was "really" on-screen).
    public static func isOnAnyMonitor(_ frame: Rect, monitors: [Rect]) -> Bool {
        monitors.contains { mon in
            frame.midX >= mon.x && frame.midX <= mon.maxX && frame.midY >= mon.y && frame.midY <= mon.maxY
        }
    }

    /// True when any pixel of the frame overlaps a monitor — catches edge clamp strips.
    public static func intersectsAnyMonitor(_ frame: Rect, monitors: [Rect]) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        return monitors.contains { mon in
            frame.x < mon.maxX && frame.maxX > mon.x && frame.y < mon.maxY && frame.maxY > mon.y
        }
    }

    /// Thin sliver glued to a monitor edge (classic macOS clamp of an "off-screen" window).
    public static func isEdgeStrip(_ frame: Rect, monitors: [Rect]) -> Bool {
        guard intersectsAnyMonitor(frame, monitors: monitors) else { return false }
        if frame.width <= 48 || frame.height <= 48 { return true }
        return monitors.contains { mon in
            let onRight = abs(frame.maxX - mon.maxX) < 3 && frame.width < mon.width * 0.15
            let onLeft = abs(frame.x - mon.x) < 3 && frame.width < mon.width * 0.15
            let onTop = abs(frame.y - mon.y) < 3 && frame.height < mon.height * 0.15
            let onBottom = abs(frame.maxY - mon.maxY) < 3 && frame.height < mon.height * 0.15
            return onRight || onLeft || onTop || onBottom
        }
    }

    /// Dock miniaturize / clamp leftovers — tiny on-screen chrome that must not be
    /// treated as a real tile (focus border hugging an empty pill).
    public static func isDockThumbnailLike(_ frame: Rect) -> Bool {
        if frame.width <= 1 || frame.height <= 1 { return true }
        if frame.width <= 160, frame.height <= 56 { return true }
        if frame.height <= 48, frame.width <= 320 { return true }
        return false
    }

    /// True when the live frame is a usable on-screen window (not park/clamp/thumb).
    public static func isUsableOnscreenFrame(_ frame: Rect, monitors: [Rect]) -> Bool {
        guard isOnAnyMonitor(frame, monitors: monitors) else { return false }
        guard !isDockThumbnailLike(frame) else { return false }
        guard !isEdgeStrip(frame, monitors: monitors) else { return false }
        return frame.width >= 120 && frame.height >= 80
    }
}
