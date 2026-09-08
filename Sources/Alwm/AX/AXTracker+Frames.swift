import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

// MARK: - AX tracker — frames park/reveal

extension AXTracker {

    public func apply(frame: Rect, to id: WindowID) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            if ax.isMinimized { ax.isMinimized = false }
            if !framesApproximatelyEqual(ax.frame, frame) {
                ax.frame = frame
            }
        }
    }


    /// Move/resize without touching minimize — used for same-workspace fluid layout.
    public func applyFrameOnly(frame: Rect, to id: WindowID) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            if framesApproximatelyEqual(ax.frame, frame) { return }
            ax.frame = frame
            // Electron often ignores the first AX write — one retry recovers size/position.
            if !framesApproximatelyEqual(ax.frame, frame, epsilon: 6) {
                ax.frame = frame
            }
        }
    }


    /// Always write geometry (stack pairs must shrink the top tile before the bottom grows).
    public func forceFrame(_ frame: Rect, id: WindowID) {
        forceStackTileFrame(frame, id: id, positionFirst: false)
    }


    /// Stack layout: top tile uses size→pos→size; lower tiles use pos→size so growth moves up.
    public func forceStackTileFrame(_ frame: Rect, id: WindowID, positionFirst: Bool) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            if ax.isMinimized { ax.isMinimized = false }
            var point = CGPoint(x: frame.x, y: frame.y)
            var size = CGSize(width: frame.width, height: frame.height)
            if positionFirst {
                if let pos = AXValueCreate(.cgPoint, &point) {
                    AXUIElementSetAttributeValue(ax.element, kAXPositionAttribute as CFString, pos)
                }
                if let sz = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(ax.element, kAXSizeAttribute as CFString, sz)
                }
                if let sz = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(ax.element, kAXSizeAttribute as CFString, sz)
                }
            } else {
                ax.frame = frame
                if !framesApproximatelyEqual(ax.frame, frame, epsilon: 6) {
                    ax.frame = frame
                }
            }
        }
    }


    public func applyParked(frame: Rect, to id: WindowID) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            if !framesApproximatelyEqual(ax.frame, frame) {
                ax.frame = frame
            }
        }
    }


    public func isMinimized(_ id: WindowID) -> Bool {
        axWindows[id]?.isMinimized ?? false
    }


    /// True when the live AX frame already matches the target (on- or off-screen).
    /// Off-screen match must count as settled — column scroll parks tiles just past the
    /// usable edge without minimize; requiring on-monitor would re-apply every tick.
    public func isSettled(id: WindowID, frame: Rect, monitors: [Rect]) -> Bool {
        guard let ax = axWindows[id], !ax.isMinimized else { return false }
        return framesApproximatelyEqual(ax.frame, frame, epsilon: 4)
    }


    public func parkAndHide(frame: Rect, id: WindowID, monitors: [Rect] = []) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            let park = monitors.isEmpty
                ? (x: frame.x, y: frame.y)
                : OffscreenParking.parkOrigin(monitors: monitors, preferred: nil)
            // Keep real size — collapsing to 1×1 is rejected by Safari/Electron and macOS
            // clamps a visible strip of the full window onto the display edge.
            let parked = OffscreenParking.parkedFrame(origin: park, sizeFrom: frame, live: ax.frame)
            ax.frame = parked
            ax.isMinimized = true
            if !framesApproximatelyEqual(ax.frame, parked, epsilon: 8) {
                ax.frame = parked
            }
        }
    }


    /// Park without minimize — use when the same app still has visible windows (minimize is per-app on Electron).
    public func parkOffscreen(frame: Rect, id: WindowID, monitors: [Rect] = []) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            let origin = monitors.isEmpty
                ? (x: frame.x, y: frame.y)
                : OffscreenParking.parkOrigin(monitors: monitors, preferred: nil)
            let parked = OffscreenParking.parkedFrame(origin: origin, sizeFrom: frame, live: ax.frame)
            ax.frame = parked
            if !framesApproximatelyEqual(ax.frame, parked, epsilon: 8) {
                ax.frame = parked
            }
        }
    }


    /// Last applied off-screen park frame for an id (best-effort readback).
    public func currentParkedFrame(of id: WindowID, sizeFrom: Rect, monitors: [Rect]) -> Rect {
        let origin = OffscreenParking.parkOrigin(monitors: monitors, preferred: nil)
        let live = axWindows[id]?.frame ?? sizeFrom
        return OffscreenParking.parkedFrame(origin: origin, sizeFrom: sizeFrom, live: live)
    }


    /// Re-hide without touching geometry (sibling deminiaturize after focusing another app window).
    public func ensureMinimized(_ id: WindowID) {
        withMutation {
            guard let ax = axWindows[id], !ax.isMinimized else { return }
            ax.isMinimized = true
        }
    }


    /// Repark when a hidden/off-screen window still bleeds onto a display (edge strip or clamp).
    /// Must not touch normal on-screen tiles — intersectsAnyMonitor alone is true for every visible window.
    public func reparkIfLeaking(id: WindowID, monitors: [Rect], allowMinimize: Bool = true) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            let frame = ax.frame
            let edgeStrip = OffscreenParking.isEdgeStrip(frame, monitors: monitors)
            let parkedBleed = OffscreenParking.intersectsAnyMonitor(frame, monitors: monitors)
                && !OffscreenParking.isUsableOnscreenFrame(frame, monitors: monitors)
            guard edgeStrip || parkedBleed else { return }
            let park = OffscreenParking.parkOrigin(monitors: monitors, preferred: nil)
            let parked = OffscreenParking.parkedFrame(origin: park, sizeFrom: frame, live: frame)
            ax.frame = parked
            if allowMinimize {
                ax.isMinimized = true
                if !framesApproximatelyEqual(ax.frame, parked, epsilon: 8) {
                    ax.frame = parked
                }
            }
        }
    }


    public func reveal(frame: Rect, id: WindowID) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            let needsFrame = !framesApproximatelyEqual(ax.frame, frame, epsilon: 4)
            let needsShow = ax.isMinimized
            // Already correct on-screen — do not touch (avoids close/reopen flash).
            guard needsFrame || needsShow else { return }

            // Place geometry first so deminiaturize never flashes at dock / park size.
            if needsFrame {
                ax.frame = frame
            }
            if needsShow {
                ax.isMinimized = false
            }
            // Always re-apply after deminiaturize: Electron/WhatsApp Chromium often keeps a
            // stale webview layout (composer clipped) unless size is written while visible.
            ax.frame = frame
            if !framesApproximatelyEqual(ax.frame, frame, epsilon: 4) {
                ax.frame = frame
            }
        }
    }


    /// Live AX frame if the window is still tracked.
    public func currentFrame(of id: WindowID) -> Rect? {
        guard let ax = axWindows[id] else { return nil }
        let f = ax.frame
        guard f.width > 1, f.height > 1 else { return nil }
        return f
    }


    /// Uncensored AX frame (includes edge-clamp strips used for leak detection).
    public func rawFrame(of id: WindowID) -> Rect? {
        guard let ax = axWindows[id] else { return nil }
        let f = ax.frame
        guard f.width > 0, f.height > 0 else { return nil }
        return f
    }


    /// Fresh title from AX / CG (not the last scan snapshot).
    public func currentTitle(of id: WindowID) -> String? {
        guard let ax = axWindows[id] else { return nil }
        let t = ax.resolvedTitle()
        return t.isEmpty ? nil : t
    }


    public func setMinimized(_ minimized: Bool, id: WindowID) {
        withMutation {
            axWindows[id]?.isMinimized = minimized
        }
    }


    public func focus(_ id: WindowID) {
        withMutation {
            axWindows[id]?.focus()
        }
    }


    @discardableResult
    public func closeWindow(_ id: WindowID) -> Bool {
        withMutation {
            axWindows[id]?.close() ?? false
        }
    }


    func framesApproximatelyEqual(_ a: Rect, _ b: Rect, epsilon: Double = 2.0) -> Bool {
        abs(a.x - b.x) < epsilon
            && abs(a.y - b.y) < epsilon
            && abs(a.width - b.width) < epsilon
            && abs(a.height - b.height) < epsilon
    }


    public func restoreAllOnscreen(monitors: [Rect]) {
        guard let first = monitors.first else { return }
        for (_, ax) in axWindows {
            var f = ax.frame
            let onAny = monitors.contains { mon in
                f.midX >= mon.x && f.midX <= mon.maxX && f.midY >= mon.y && f.midY <= mon.maxY
            }
            if !onAny {
                f.x = first.x + 40
                f.y = first.y + 40
                f.width = min(f.width, first.width - 80)
                f.height = min(f.height, first.height - 80)
                ax.frame = f
            }
            if ax.isMinimized { ax.isMinimized = false }
        }
    }


    /// Focused window of the frontmost app, if we track it.
    public func frontmostFocusedWindowID() -> WindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let el = focused else { return nil }
        return windowID(for: el as! AXUIElement)
    }

    public var currentWindows: [ManagedWindow] { Array(managed.values) }

    public var currentAX: [WindowID: AXWindow] { axWindows }

}
