import AppKit
import Foundation
import AlwmPluginAPI

// MARK: - Workspace bar — menus

extension WorkspaceBarController {

    /// When one icon represents several windows from the same app in a workspace,
    /// offer explicit per-window selection instead of focusing an arbitrary one.
    func workspaceAppCandidates(
        monitorID: CGDirectDisplayID,
        workspaceID: String,
        app: ManagedWindow
    ) -> [ManagedWindow] {
        let bid = app.bundleID
        let appPID = app.id.pid

        // ── Primary: ask the WindowManager directly (most up-to-date, handles token churn) ──
        if let live = onWindowsForApp?(bid ?? "", app.appName, workspaceID), !live.isEmpty {
            return live.sorted {
                let t0 = $0.title.isEmpty ? $0.appName : $0.title
                let t1 = $1.title.isEmpty ? $1.appName : $1.title
                return t0.localizedCaseInsensitiveCompare(t1) == .orderedAscending
            }
        }

        // ── Fallback: derive from cached snapshots when the callback is unavailable ──
        var candidateIDs = Set<WindowID>()
        if let ws = lastWorkspaces[workspaceID] {
            candidateIDs.formUnion(ws.columns.flatMap(\.windows))
        }
        for (id, home) in lastWindowWorkspace where home == workspaceID {
            candidateIDs.insert(id)
        }

        func matches(_ win: ManagedWindow) -> Bool {
            guard !win.isIgnored, !win.isScratchpad else { return false }
            if let bid = bid, !bid.isEmpty { return win.bundleID == bid }
            if win.id.pid == appPID { return true }
            return win.appName == app.appName
        }

        var seen = Set<WindowID>()
        var filtered: [ManagedWindow] = []

        for id in candidateIDs {
            if let win = lastWindowsByID[id], matches(win), seen.insert(id).inserted {
                filtered.append(win)
            }
        }
        for (id, win) in lastWindowsByID {
            guard matches(win), seen.insert(id).inserted else { continue }
            let assignedWS = lastWindowWorkspace[id]
            if assignedWS == workspaceID || assignedWS == nil {
                filtered.append(win)
            }
        }

        return filtered.sorted {
            let t0 = $0.title.isEmpty ? $0.appName : $0.title
            let t1 = $1.title.isEmpty ? $1.appName : $1.title
            return t0.localizedCaseInsensitiveCompare(t1) == .orderedAscending
        }
    }


    func makeAppPickMenu(
        candidates: [ManagedWindow],
        monitorID: CGDirectDisplayID,
        workspaceID: String
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let homes = Set(candidates.compactMap { lastWindowWorkspace[$0.id] })
        let showHomeLabel = homes.count > 1 || homes.contains(where: { $0 != workspaceID })
        for win in candidates {
            let windowTitle = win.title.isEmpty ? win.appName : win.title
            let home = lastWindowWorkspace[win.id] ?? workspaceID
            let homeName = menuWorkspaces.first(where: { $0.0 == home })?.1 ?? home
            let title = showHomeLabel ? "\(windowTitle)  ·  \(homeName)" : windowTitle
            let item = NSMenuItem(
                title: title,
                action: #selector(WorkspaceBarActionBridge.menuFocusWindow(_:)),
                keyEquivalent: ""
            )
            item.target = actionBridge
            // Pass the window's own home so focus switches to the right workspace/monitor.
            item.representedObject = "\(monitorID)|\(home)|\(win.id.token)"
            item.image = icon(for: win, size: 12)
            item.isEnabled = true
            menu.addItem(item)
        }
        return menu
    }


    func makeWorkspaceContextMenu(
        monitorID: CGDirectDisplayID,
        workspaceID: String,
        workspaceName: String
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let switchItem = NSMenuItem(
            title: String(format: L10n.t("wsbar.menu.switch_to"), workspaceName),
            action: #selector(WorkspaceBarActionBridge.menuSwitchWorkspace(_:)),
            keyEquivalent: ""
        )
        switchItem.target = actionBridge
        switchItem.representedObject = "\(monitorID)|\(workspaceID)"
        switchItem.isEnabled = true
        menu.addItem(switchItem)
        menu.addItem(.separator())

        let moveHere = NSMenuItem(
            title: L10n.t("wsbar.menu.move_here"),
            action: #selector(WorkspaceBarActionBridge.menuMoveFocusedHere(_:)),
            keyEquivalent: ""
        )
        moveHere.target = actionBridge
        moveHere.representedObject = workspaceID
        moveHere.isEnabled = true
        menu.addItem(moveHere)

        let moveFollow = NSMenuItem(
            title: L10n.t("wsbar.menu.move_here_follow"),
            action: #selector(WorkspaceBarActionBridge.menuMoveFocusedHereFollow(_:)),
            keyEquivalent: ""
        )
        moveFollow.target = actionBridge
        moveFollow.representedObject = workspaceID
        moveFollow.isEnabled = true
        menu.addItem(moveFollow)

        return menu
    }


    func makeAppContextMenu(
        for app: ManagedWindow,
        monitorID: CGDirectDisplayID,
        workspaceID: String
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let token = app.id.token

        let focus = NSMenuItem(
            title: L10n.t("wsbar.menu.focus"),
            action: #selector(WorkspaceBarActionBridge.menuFocusWindow(_:)),
            keyEquivalent: ""
        )
        focus.target = actionBridge
        focus.representedObject = "\(monitorID)|\(workspaceID)|\(token)"
        focus.isEnabled = true
        menu.addItem(focus)

        menu.addItem(.separator())

        let close = NSMenuItem(
            title: L10n.t("wsbar.menu.close_window"),
            action: #selector(WorkspaceBarActionBridge.menuCloseWindow(_:)),
            keyEquivalent: ""
        )
        close.target = actionBridge
        close.representedObject = token
        close.isEnabled = true
        menu.addItem(close)

        let quitTitle = String(format: L10n.t("wsbar.menu.quit_app"), app.appName.isEmpty ? "App" : app.appName)
        let quit = NSMenuItem(
            title: quitTitle,
            action: #selector(WorkspaceBarActionBridge.menuQuitApp(_:)),
            keyEquivalent: ""
        )
        quit.target = actionBridge
        quit.representedObject = NSNumber(value: app.id.pid)
        quit.isEnabled = true
        menu.addItem(quit)

        menu.addItem(.separator())

        let floatTitle = app.isFloating ? L10n.t("wsbar.menu.tile") : L10n.t("wsbar.menu.float")
        let floatItem = NSMenuItem(
            title: floatTitle,
            action: #selector(WorkspaceBarActionBridge.menuToggleFloat(_:)),
            keyEquivalent: ""
        )
        floatItem.target = actionBridge
        floatItem.representedObject = token
        floatItem.isEnabled = true
        menu.addItem(floatItem)

        let moveSub = NSMenu(title: L10n.t("wsbar.menu.move_to"))
        moveSub.autoenablesItems = false
        for ws in menuWorkspaces where ws.id != workspaceID {
            let item = NSMenuItem(
                title: ws.name,
                action: #selector(WorkspaceBarActionBridge.menuMoveWindowToWorkspace(_:)),
                keyEquivalent: ""
            )
            item.target = actionBridge
            item.representedObject = "\(token)|\(ws.id)|0"
            item.isEnabled = true
            moveSub.addItem(item)
        }
        if !moveSub.items.isEmpty {
            let moveParent = NSMenuItem(title: L10n.t("wsbar.menu.move_to"), action: nil, keyEquivalent: "")
            moveParent.submenu = moveSub
            menu.addItem(moveParent)

            let moveFollowSub = NSMenu(title: L10n.t("wsbar.menu.move_to_follow"))
            moveFollowSub.autoenablesItems = false
            for ws in menuWorkspaces where ws.id != workspaceID {
                let item = NSMenuItem(
                    title: ws.name,
                    action: #selector(WorkspaceBarActionBridge.menuMoveWindowToWorkspace(_:)),
                    keyEquivalent: ""
                )
                item.target = actionBridge
                item.representedObject = "\(token)|\(ws.id)|1"
                item.isEnabled = true
                moveFollowSub.addItem(item)
            }
            let followParent = NSMenuItem(title: L10n.t("wsbar.menu.move_to_follow"), action: nil, keyEquivalent: "")
            followParent.submenu = moveFollowSub
            menu.addItem(followParent)
        }

        return menu
    }


    func parseWindowToken(_ token: String) -> WindowID? {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let pid = Int32(parts[0]), let winNum = Int(parts[1]) else { return nil }
        return WindowID(pid: pid, windowNumber: winNum)
    }
}
