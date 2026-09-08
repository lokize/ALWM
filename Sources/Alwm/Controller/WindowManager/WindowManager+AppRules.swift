import AppKit
import ApplicationServices
import Foundation
import SwiftUI
import AlwmIPC
import AlwmPluginAPI

// MARK: - App rules — float/placement enforcement

extension WindowManager {
    func enforceAppRuleFloats() -> Set<String> {
        let rules = configStore.config.rules
        var stripped: Set<String> = []
        for (id, win) in windowsByID {
            guard !win.isIgnored, AppRules.forcesFloat(rules: rules, window: win) else { continue }
            var floating = win
            floating.isFloating = true
            windowsByID[id] = floating
            forcedTiledUntil.removeValue(forKey: id)
            if let wsID = workspaces.workspaceID(containing: id) {
                stripped.insert(wsID)
                workspaces.removeWindowEverywhere(id)
            }
            ensureFloatHome(id, win: floating)
            if let home = windowWorkspace[id], isHomeActiveOnAnyMonitor(home) {
                markFloatRevealProtected(id)
            }
        }
        return stripped
    }

    func reapplyAppRulesToAllWindows() {
        let rules = configStore.config.rules
        guard !windowsByID.isEmpty else { return }

        for (id, win) in windowsByID {
            var applied = AppRules.apply(rules: rules, to: win)
            if isQuakeOwned(id) || quake.windowID == id {
                applied.isFloating = true
                applied.isScratchpad = true
                floatingOverrides.insert(id)
            } else if AppRules.forcesFloat(rules: rules, window: applied) {
                applied.isFloating = true
            } else if floatingOverrides.contains(id) {
                applied.isFloating = true
            } else if applied.isIgnored {
                applied.isFloating = false
            } else if workspaces.workspaceID(containing: id) != nil
                || windowWorkspace[id] != nil
                || runtimeState.assignment(for: id) != nil {
                applied.isFloating = false
            }
            windowsByID[id] = applied
        }

        enforceAppRuleFloats()

        for id in windowsByID.keys {
            applyAppRulePlacement(to: id)
        }
    }

    func applyAppRulesNow() {
        forceAppRuleFrameApply = true
        reapplyAppRulesToAllWindows()
        forceAppRuleFrameApply = false
        relayout(animated: true)
        refreshChrome()
        refreshStatusItem()
    }

    func runningAppsForRules() -> [AppRuleRunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
            .compactMap { app -> AppRuleRunningApp? in
                guard let bid = app.bundleIdentifier else { return nil }
                let name = app.localizedName ?? bid
                return AppRuleRunningApp(bundleID: bid, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func captureAppRuleGeometry(bundleID: String?) -> AppRuleCapturedGeometry? {
        guard let win = bestWindowForRuleCapture(bundleID: bundleID) else { return nil }
        let frame = ax.currentFrame(of: win.id) ?? win.frame
        let monitor = monitors.monitorContaining(pointX: frame.midX, pointY: frame.midY)
            ?? primaryMonitor()
        guard let monitor else { return nil }
        let idx = monitors.monitors.firstIndex(where: { $0.id == monitor.id }) ?? 0
        var geo = AppRules.geometry(from: frame, on: monitor, monitorIndex: idx)
        geo.workspace = authoritativeHome(for: win.id)
        geo.isFloating = win.isFloating || win.isScratchpad
        return geo
    }

    func bestWindowForRuleCapture(bundleID: String?) -> ManagedWindow? {
        let bid = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bid, !bid.isEmpty {
            if let focused = ax.frontmostFocusedWindowID(),
               let front = windowsByID[focused],
               front.bundleID == bid,
               !front.isIgnored {
                return front
            }
            let matches = windowsByID.values.filter { $0.bundleID == bid && !$0.isIgnored }
            return matches.max(by: { a, b in
                let aa = a.frame.width * a.frame.height
                let bb = b.frame.width * b.frame.height
                return aa < bb
            })
        }
        if let focused = ax.frontmostFocusedWindowID(),
           let front = windowsByID[focused],
           !front.isIgnored {
            return front
        }
        return nil
    }

    func monitorForAppRule(_ rule: AppRule, window: ManagedWindow) -> MonitorInfo? {
        if let idx = rule.monitorIndex, monitors.monitors.indices.contains(idx) {
            return monitors.monitors[idx]
        }
        if let ws = AppRules.preferredWorkspace(rules: configStore.config.rules, window: window),
           let mon = workspaces.preferredMonitor(forWorkspace: ws, monitors: monitors.monitors) {
            return mon
        }
        return monitors.monitorContaining(pointX: window.frame.midX, pointY: window.frame.midY)
            ?? primaryMonitor()
    }

    func applyRuleFrame(_ frame: Rect, to id: WindowID) {
        let monitors = monitors.monitors.map(\.frame)
        if ax.isSettled(id: id, frame: frame, monitors: monitors) {
            lastFrames[id] = frame
            savedFrames[id] = frame
            return
        }
        ax.suppressNotifications(for: 0.2)
        ax.reveal(frame: frame, id: id)
        ax.applyFrameOnly(frame: frame, to: id)
        lastFrames[id] = frame
        savedFrames[id] = frame
    }

    func applyAppRulePlacement(to id: WindowID) {
        guard let win = windowsByID[id], !win.isIgnored else { return }
        guard !isQuakeOwned(id), quake.windowID != id else { return }
        let rules = configStore.config.rules
        guard let rule = AppRules.matching(rules: rules, window: win) else { return }
        guard let monitor = monitorForAppRule(rule, window: win) else { return }

        if let preferred = AppRules.preferredWorkspace(rules: rules, window: win),
           workspaces.workspaces[preferred] != nil {
            if win.isTiled {
                if windowWorkspace[id] != preferred || workspaces.workspaceID(containing: id) != preferred {
                    assignWindow(id, to: preferred, on: monitor)
                }
            } else {
                windowWorkspace[id] = preferred
                runtimeState.setAssignment(preferred, for: id)
            }
        }

        let shouldApplyFrame = forceAppRuleFrameApply || !appRuleFramesApplied.contains(id)
        if shouldApplyFrame,
           win.isFloating || rule.mode == .float,
           let frame = AppRules.targetFrame(rule: rule, monitor: monitor, fallback: win.frame) {
            applyRuleFrame(frame, to: id)
            appRuleFramesApplied.insert(id)
            if var updated = windowsByID[id] {
                updated.frame = frame
                windowsByID[id] = updated
            }
        }
    }

}
