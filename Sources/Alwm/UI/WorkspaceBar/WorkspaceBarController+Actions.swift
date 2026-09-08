import AppKit
import Foundation
import AlwmPluginAPI

// MARK: - Workspace bar — click/menu actions

extension WorkspaceBarController {

    func floatClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              raw.hasPrefix("float|"),
              let mon = UInt32(raw.dropFirst("float|".count)) else { return }
        onFocusFloatingOnMonitor?(CGDirectDisplayID(mon))
    }


    func workspaceClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        let parts = raw.split(separator: "|")
        guard parts.count == 2, let mon = UInt32(parts[0]) else { return }
        onSelectWorkspace?(CGDirectDisplayID(mon), String(parts[1]))
    }


    func focusedStatusClicked(_ sender: NSButton) {
        onFocusedStatusClicked?(sender)
    }


    func appIconClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue else { return }
        let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let mon = UInt32(parts[0]) else { return }
        let tokenParts = parts[2].split(separator: ":", maxSplits: 1).map(String.init)
        guard tokenParts.count == 2,
              let pid = Int32(tokenParts[0]),
              let winNum = Int(tokenParts[1])
        else { return }
        let clickedID = WindowID(pid: pid, windowNumber: winNum)
        let monID = CGDirectDisplayID(mon)
        let workspaceID = parts[1]

        // Try to find the representative ManagedWindow for this icon.
        // Prefer exact match; fall back to any live window with the same pid (token churn).
        let app: ManagedWindow? = lastWindowsByID[clickedID]
            ?? lastWindowsByID.values.first(where: { $0.id.pid == clickedID.pid && !$0.isIgnored })

        if let app {
            let candidates = workspaceAppCandidates(monitorID: monID, workspaceID: workspaceID, app: app)
            if candidates.count > 1 {
                let menu = makeAppPickMenu(candidates: candidates, monitorID: monID, workspaceID: workspaceID)
                let anchor = NSPoint(x: sender.bounds.midX, y: sender.bounds.maxY + 4)
                menu.popUp(positioning: nil, at: anchor, in: sender)
                return
            }
        }
        onFocusWorkspaceWindow?(monID, workspaceID, clickedID)
    }


    func menuSwitchWorkspace(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|").map(String.init)
        guard parts.count == 2, let mon = UInt32(parts[0]) else { return }
        onSelectWorkspace?(CGDirectDisplayID(mon), parts[1])
    }


    func menuMoveFocusedHere(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onMoveFocusedToWorkspace?(id, false)
    }


    func menuMoveFocusedHereFollow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onMoveFocusedToWorkspace?(id, true)
    }


    func menuFocusWindow(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let mon = UInt32(parts[0]), let wid = parseWindowToken(parts[2]) else { return }
        onFocusWorkspaceWindow?(CGDirectDisplayID(mon), parts[1], wid)
    }


    func menuCloseWindow(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String, let id = parseWindowToken(token) else { return }
        onCloseWindow?(id)
    }


    func menuQuitApp(_ sender: NSMenuItem) {
        guard let num = sender.representedObject as? NSNumber else { return }
        onQuitApp?(pid_t(num.int32Value))
    }


    func menuToggleFloat(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? String, let id = parseWindowToken(token) else { return }
        onToggleFloatWindow?(id)
    }


    func menuMoveWindowToWorkspace(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|").map(String.init)
        guard parts.count == 3, let wid = parseWindowToken(parts[0]) else { return }
        let follow = parts[2] == "1"
        onMoveWindowToWorkspace?(wid, parts[1], follow)
    }
}
