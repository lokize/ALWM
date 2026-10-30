import AppKit
import CoreGraphics
import Foundation

/// A clickable window target for the capture overlay.
struct CaptureWindowTarget: Equatable, Sendable {
    let id: CGWindowID
    /// Global Cocoa rectangle (bottom-left origin, spans screens).
    let frame: NSRect
    let title: String
}

/// Resolves on-screen windows from the cursor position using the Window Server list.
///
/// The overlay sits above every app, so clicks never reach the real windows. We use
/// `CGWindowListCopyWindowInfo` to find what the user is pointing at, then ScreenCaptureKit
/// drives the actual capture.
enum CaptureWindowFinder {
    /// Height of the primary display, used to flip between Cocoa (bottom-left) and
    /// Window Server (top-left) global coordinates.
    static var primaryDisplayHeight: CGFloat {
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return primary.frame.maxY
        }
        return NSScreen.screens.first?.frame.height ?? 0
    }

    /// Converts a Window Server / ScreenCaptureKit rectangle to global Cocoa coordinates.
    static func cocoaFrame(fromCG frame: CGRect) -> NSRect {
        NSRect(
            x: frame.minX,
            y: primaryDisplayHeight - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// Topmost normal window under a global Cocoa point. Excludes ALWM's own windows.
    static func window(atGlobalCocoaPoint point: NSPoint) -> CaptureWindowTarget? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = primaryDisplayHeight
        let cgPoint = CGPoint(x: point.x, y: primaryHeight - point.y)

        for info in raw {
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { continue }
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != ownPID else { continue }
            guard (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0.01 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let x = (bounds["X"] as? NSNumber)?.doubleValue,
                  let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                  let w = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let h = (bounds["Height"] as? NSNumber)?.doubleValue,
                  w >= 24, h >= 24,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { continue }

            let cgFrame = CGRect(x: x, y: y, width: w, height: h)
            guard cgFrame.contains(cgPoint) else { continue }

            let title = (info[kCGWindowName as String] as? String)
                ?? (info[kCGWindowOwnerName as String] as? String)
                ?? ""
            return CaptureWindowTarget(
                id: CGWindowID(id),
                frame: cocoaFrame(fromCG: cgFrame),
                title: title
            )
        }
        return nil
    }

    /// Pixel/point scale for a captured window frame (falls back to the main display).
    static func backingScale(forWindowFrame frame: CGRect) -> CGFloat {
        let cocoa = cocoaFrame(fromCG: frame)
        let scales = NSScreen.screens
            .filter { $0.frame.intersects(cocoa) }
            .map(\.backingScaleFactor)
        return scales.max() ?? NSScreen.main?.backingScaleFactor ?? 2
    }
}
