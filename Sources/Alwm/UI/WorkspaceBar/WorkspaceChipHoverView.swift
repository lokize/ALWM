import AppKit
import Foundation
import AlwmPluginAPI

// MARK: - Chip hover view

final class WorkspaceChipHoverView: NSView {
    var isActiveWorkspace = false
    var accentColor: NSColor = .systemTeal
    var isHovered = false
    var tracking: NSTrackingArea?
    let hoverTracker = WorkspaceChipHoverTracker()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        hoverTracker.chip = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: hoverTracker,
            userInfo: nil
        )
        tracking = area
        addTrackingArea(area)
    }

    var isMouseInside: Bool {
        guard let window else { return false }
        let loc = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(loc)
    }

    func setHovered(_ on: Bool) {
        guard isHovered != on else { return }
        isHovered = on
        applyHoverAppearance(animated: true)
    }

    func applyHoverAppearance(animated: Bool = false) {
        wantsLayer = true
        layer?.cornerCurve = .continuous
        let color: NSColor = {
            if isHovered {
                return NSColor.white.withAlphaComponent(0.14)
            }
            if isActiveWorkspace {
                return accentColor.withAlphaComponent(0.28)
            }
            return .clear
        }()
        let apply = { self.layer?.backgroundColor = color.cgColor }
        if animated, let layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            apply()
            CATransaction.commit()
            _ = layer
        } else {
            apply()
        }
    }
}
