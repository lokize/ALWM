import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

// MARK: - AX tracker delegate

public protocol AXTrackerDelegate: AnyObject {
    func axTrackerDidUpdateWindows(_ windows: [ManagedWindow], axWindows: [WindowID: AXWindow])
    func axTrackerFocusedWindowDidChange(_ id: WindowID?)
    /// Title-only update (Electron/tab apps) — must not trigger full ingest.
    func axTrackerWindowTitleDidChange(_ id: WindowID, window: ManagedWindow)
    /// External (or user) move/resize of a tracked window — enforce tiled layout if drifted.
    func axTrackerWindowGeometryChanged(_ id: WindowID)
    /// Window element destroyed (user clicked the red X) — handle before soft-delete lag.
    func axTrackerWindowDidClose(_ id: WindowID)
}
