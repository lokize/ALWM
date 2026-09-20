import AppKit
import Foundation

extension WindowManager {
    /// After a workspace switch: open session apps and optionally quit others.
    func applyNamedSession(for workspaceID: String) {
        guard !isBootstrapping, !isResumeRecovering, !isLayoutMutationFrozen else { return }
        guard let destination = configStore.config.workspaces.first(where: { $0.id == workspaceID }) else {
            return
        }

        let toLaunch = destination.sessionApps.filter { bundleID in
            !isSessionAppRunning(bundleID)
        }
        for bundleID in toLaunch {
            openSessionApp(bundleID: bundleID)
        }

        guard destination.sessionQuitOthers, !destination.sessionApps.isEmpty else { return }

        let keep = activeSessionKeepBundleIDs()
        guard !keep.isEmpty else { return }

        // Give launches a head start before quitting outsiders.
        let generation = workspaceSwitchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self else { return }
            guard self.workspaceSwitchGeneration == generation else { return }
            guard !self.isBootstrapping, !self.isResumeRecovering, !self.isLayoutMutationFrozen else { return }
            self.quitAppsOutsideSession(keepBundleIDs: keep)
        }
    }

    /// Bundle IDs that must stay alive across all currently active workspaces.
    func activeSessionKeepBundleIDs() -> Set<String> {
        var keep = Set<String>()
        let defs = configStore.config.workspaces
        let activeIDs = Set(workspaces.activeWorkspaceByMonitor.values)
        for def in defs where activeIDs.contains(def.id) {
            for bid in def.sessionApps {
                let trimmed = bid.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { keep.insert(trimmed) }
            }
        }
        return keep
    }

    func isSessionAppRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            !$0.isTerminated && $0.bundleIdentifier == bundleID
        }
    }

    func openSessionApp(bundleID: String) {
        let bid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bid.isEmpty else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) else {
            logMove("session open miss bundle=\(bid)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            if let error {
                Task { @MainActor in
                    self?.logMove("session open fail bundle=\(bid) err=\(error.localizedDescription)")
                }
            } else {
                Task { @MainActor in
                    self?.logMove("session open ok bundle=\(bid)")
                }
            }
        }
    }

    func quitAppsOutsideSession(keepBundleIDs: Set<String>) {
        guard !isBootstrapping, !isResumeRecovering, !isLayoutMutationFrozen else { return }
        let keepLower = Set(keepBundleIDs.map { $0.lowercased() })
        let candidates = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular
        }
        for app in candidates {
            guard let bid = app.bundleIdentifier else { continue }
            if keepLower.contains(bid.lowercased()) { continue }
            if shouldProtectFromSessionQuit(bundleID: bid, pid: app.processIdentifier) { continue }
            logMove("session quit bundle=\(bid) pid=\(app.processIdentifier)")
            quitApp(pid: app.processIdentifier)
        }
    }

    func shouldProtectFromSessionQuit(bundleID: String, pid: pid_t) -> Bool {
        if pid == ProcessInfo.processInfo.processIdentifier { return true }
        let bid = bundleID.lowercased()
        if bid.hasPrefix("dev.alwm") || bid.contains(".alwm") { return true }
        if bid == "com.apple.finder" { return true }
        if bid.hasPrefix("com.apple.dock") || bid.hasPrefix("com.apple.systemuiserver") { return true }
        if bid.hasPrefix("com.apple.controlcenter") || bid.hasPrefix("com.apple.notificationcenterui") {
            return true
        }
        if let qid = quake.windowID, qid.pid == pid { return true }
        if let session = quakeSessionBundleID()?.lowercased(), bid == session { return true }
        if windowsByID.values.contains(where: { $0.id.pid == pid && $0.isScratchpad }) { return true }
        return false
    }
}
