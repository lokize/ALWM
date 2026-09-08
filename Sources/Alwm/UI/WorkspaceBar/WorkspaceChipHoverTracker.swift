import AppKit
import Foundation
import AlwmPluginAPI

// MARK: - Chip hover tracker

final class WorkspaceChipHoverTracker: NSObject {
    nonisolated(unsafe) weak var chip: WorkspaceChipHoverView?

    @objc func mouseEntered(_ event: NSEvent) {
        let chip = self.chip
        Task { @MainActor in
            chip?.setHovered(true)
        }
    }

    @objc func mouseExited(_ event: NSEvent) {
        let chip = self.chip
        Task { @MainActor in
            guard let chip else { return }
            chip.setHovered(chip.isMouseInside)
        }
    }
}
