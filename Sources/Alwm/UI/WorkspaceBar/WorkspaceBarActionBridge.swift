import AppKit
import Foundation
import AlwmPluginAPI

// MARK: - Action bridge to MainActor

final class WorkspaceBarActionBridge: NSObject {
    nonisolated(unsafe) weak var owner: WorkspaceBarController?

    func hop(_ body: @escaping @MainActor (WorkspaceBarController) -> Void) {
        let owner = self.owner
        Task { @MainActor in
            guard let owner else { return }
            body(owner)
        }
    }

    /// Pass the button via bitPattern (Sendable).
    func hopButton(_ sender: NSButton, _ body: @escaping @MainActor (WorkspaceBarController, NSButton) -> Void) {
        let owner = self.owner
        let addr = Int(bitPattern: Unmanaged.passUnretained(sender).toOpaque())
        Task { @MainActor in
            guard let owner,
                  let ptr = UnsafeRawPointer(bitPattern: addr) else { return }
            let button = Unmanaged<NSButton>.fromOpaque(ptr).takeUnretainedValue()
            body(owner, button)
        }
    }

    func hopMenuItem(_ sender: NSMenuItem, _ body: @escaping @MainActor (WorkspaceBarController, NSMenuItem) -> Void) {
        let owner = self.owner
        // Use bitPattern to cross the Sendable boundary safely — the item is
        // retained by the NSMenu for the lifetime of the run loop iteration.
        let addr = Int(bitPattern: Unmanaged.passRetained(sender).toOpaque())
        Task { @MainActor in
            guard let owner else {
                // Balance the retain
                _ = Unmanaged<NSMenuItem>.fromOpaque(UnsafeRawPointer(bitPattern: addr)!).takeRetainedValue()
                return
            }
            let item = Unmanaged<NSMenuItem>.fromOpaque(UnsafeRawPointer(bitPattern: addr)!).takeRetainedValue()
            body(owner, item)
        }
    }

    @objc func floatClicked(_ sender: NSButton) {
        hopButton(sender) { $0.floatClicked($1) }
    }

    @objc func workspaceClicked(_ sender: NSButton) {
        hopButton(sender) { $0.workspaceClicked($1) }
    }

    @objc func focusedStatusClicked(_ sender: NSButton) {
        hopButton(sender) { $0.focusedStatusClicked($1) }
    }

    @objc func appIconClicked(_ sender: NSButton) {
        hopButton(sender) { $0.appIconClicked($1) }
    }

    @objc func menuSwitchWorkspace(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuSwitchWorkspace($1) }
    }

    @objc func menuMoveFocusedHere(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuMoveFocusedHere($1) }
    }

    @objc func menuMoveFocusedHereFollow(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuMoveFocusedHereFollow($1) }
    }

    @objc func menuFocusWindow(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuFocusWindow($1) }
    }

    @objc func menuCloseWindow(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuCloseWindow($1) }
    }

    @objc func menuQuitApp(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuQuitApp($1) }
    }

    @objc func menuToggleFloat(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuToggleFloat($1) }
    }

    @objc func menuMoveWindowToWorkspace(_ sender: NSMenuItem) {
        hopMenuItem(sender) { $0.menuMoveWindowToWorkspace($1) }
    }
}
