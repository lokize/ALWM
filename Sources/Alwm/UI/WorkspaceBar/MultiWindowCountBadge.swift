import AppKit
import Foundation
import AlwmPluginAPI

// MARK: - Multi-window count badge

final class MultiWindowCountBadge: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
