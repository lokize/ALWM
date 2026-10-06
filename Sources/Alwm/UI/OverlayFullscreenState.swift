import Foundation

/// Preserves the overlay's prior frame while it is expanded to its whole display.
struct OverlayFullscreenState {
    private(set) var isFullscreen = false
    private var restoredFrame: Rect?

    mutating func toggle(currentFrame: Rect, displayFrame: Rect) -> Rect {
        if isFullscreen, let restoredFrame {
            self.restoredFrame = nil
            isFullscreen = false
            return restoredFrame
        }
        restoredFrame = currentFrame
        isFullscreen = true
        return displayFrame
    }
}
