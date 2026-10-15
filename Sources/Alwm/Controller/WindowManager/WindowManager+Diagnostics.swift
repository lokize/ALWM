import AppKit
import Foundation

extension WindowManager {
    func diagnoseWorkspaceState() -> WorkspaceDiagnosticReport {
        guard AXTracker.isTrusted, ax.lastScanTrusted else {
            return WorkspaceDiagnosticReport(
                scanComplete: false,
                windowCount: 0,
                issues: [WorkspaceDiagnosticIssue(
                    kind: .accessibilityUnavailable,
                    severity: .error,
                    detail: "Accessibility access is unavailable; window state could not be checked."
                )]
            )
        }

        var issues: [WorkspaceDiagnosticIssue] = []
        let liveIDs = Set(windowsByID.keys)
        let logicalIndices = workspaces.logicalMonitorIndices(for: monitors.monitors)
        let definitions = Dictionary(uniqueKeysWithValues: configStore.config.workspaces.map { ($0.id, $0) })

        for window in windowsByID.values where !window.isIgnored && !window.isScratchpad {
            let id = window.id
            let actualWorkspace = workspaces.workspaceID(containing: id) ?? windowWorkspace[id]
            let expectedWorkspace = runtimeState.snapshot.windowWorkspace[id.token]
                ?? window.bundleID.flatMap { runtimeState.snapshot.bundleWorkspace[$0] }

            if let expectedWorkspace, let actualWorkspace, expectedWorkspace != actualWorkspace {
                issues.append(WorkspaceDiagnosticIssue(
                    kind: .wrongWorkspace,
                    severity: .error,
                    appName: window.appName,
                    bundleID: window.bundleID,
                    windowToken: id.token,
                    workspaceID: actualWorkspace,
                    expected: "Workspace \(expectedWorkspace)",
                    observed: "Workspace \(actualWorkspace)",
                    detail: "The saved home workspace differs from the current workspace assignment."
                ))
            }

            guard let actualWorkspace,
                  let definition = definitions[actualWorkspace],
                  let expectedIndex = definition.monitorIndex else { continue }
            let centerX = window.frame.x + window.frame.width / 2
            let centerY = window.frame.y + window.frame.height / 2
            let observedMonitor = monitors.monitors.first {
                centerX >= $0.frame.x && centerX < $0.frame.x + $0.frame.width
                    && centerY >= $0.frame.y && centerY < $0.frame.y + $0.frame.height
            }
            if let observedMonitor,
               let observedIndex = logicalIndices[observedMonitor.id],
               observedIndex != expectedIndex {
                issues.append(WorkspaceDiagnosticIssue(
                    kind: .wrongMonitor,
                    severity: .error,
                    appName: window.appName,
                    bundleID: window.bundleID,
                    windowToken: id.token,
                    workspaceID: actualWorkspace,
                    expected: "Monitor \(expectedIndex)",
                    observed: "Monitor \(observedIndex) (\(observedMonitor.name))",
                    detail: "The window is on a display different from its workspace assignment."
                ))
            }

            if window.isTiled, !window.isMinimized,
               workspaces.activeWorkspaceByMonitor.values.contains(actualWorkspace),
               let expectedFrame = lastFrames[id], !approximatelyEqual(window.frame, expectedFrame, tolerance: 20) {
                issues.append(WorkspaceDiagnosticIssue(
                    kind: .offLayout,
                    severity: .warning,
                    appName: window.appName,
                    bundleID: window.bundleID,
                    windowToken: id.token,
                    workspaceID: actualWorkspace,
                    expected: frameDescription(expectedFrame),
                    observed: frameDescription(window.frame),
                    detail: "The visible window frame differs from ALWM's last calculated tile frame."
                ))
            }
        }

        for (workspaceID, snapshot) in runtimeState.snapshot.workspaceLayouts {
            let refs = snapshot.columns.flatMap(\.windows) + snapshot.floating
            for ref in refs where !savedReference(ref, matches: liveIDs) {
                // A saved reference is only diagnostic evidence after a trusted AX scan.
                issues.append(WorkspaceDiagnosticIssue(
                    kind: .missingWindow,
                    severity: .warning,
                    appName: ref.appName.isEmpty ? nil : ref.appName,
                    bundleID: ref.bundleID,
                    windowToken: ref.token,
                    workspaceID: workspaceID,
                    expected: "Workspace \(workspaceID)",
                    observed: "No matching live window",
                    detail: "A window saved in this workspace was not found in the Accessibility scan."
                ))
            }
        }

        let runningBundles = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let activeWorkspaceIDs = Set(workspaces.activeWorkspaceByMonitor.values)
        for definition in configStore.config.workspaces {
            guard activeWorkspaceIDs.contains(definition.id) else { continue }
            let missing = definition.sessionApps.filter { !runningBundles.contains($0) }
            if !missing.isEmpty {
                issues.append(WorkspaceDiagnosticIssue(
                    kind: .incompleteSession,
                    severity: .warning,
                    workspaceID: definition.id,
                    expected: missing.joined(separator: ", "),
                    observed: "App not running",
                    detail: "The named session is missing \(missing.count) configured app(s)."
                ))
            }
        }

        return WorkspaceDiagnosticReport(scanComplete: true, windowCount: windowsByID.count, issues: issues)
    }

    /// Uses the same recovery path as wake/start restoration, then explicitly lays out and verifies.
    /// This is safe to repeat and does not close unrelated apps.
    func repairWorkspaceState() -> WorkspaceDiagnosticReport {
        guard AXTracker.isTrusted else { return diagnoseWorkspaceState() }
        runLayoutRecovery(force: true)
        restoreSavedSessionApps()
        let activeWorkspaceIDs = Set(workspaces.activeWorkspaceByMonitor.values)
        for definition in configStore.config.workspaces where activeWorkspaceIDs.contains(definition.id) {
            for bundleID in definition.sessionApps where !isSessionAppRunning(bundleID) {
                openSessionApp(bundleID: bundleID)
            }
        }
        forceRelayoutActiveWorkspaces()
        ax.scanAll()
        refreshChrome()
        return diagnoseWorkspaceState()
    }

    func showRepairSummary(_ report: WorkspaceDiagnosticReport) {
        let alert = NSAlert()
        alert.messageText = report.scanComplete ? "Diagnóstico de janelas concluído" : "Diagnóstico incompleto"
        if !report.scanComplete {
            alert.informativeText = "Permita o acesso à Acessibilidade para que o ALWM possa analisar e corrigir janelas."
        } else if report.issueCount == 0 {
            alert.informativeText = "Todas as janelas verificadas estão alinhadas com o estado do workspace."
        } else {
            alert.informativeText = "\(report.issueCount) problema(s) ainda precisam de atenção. Abra Configurações → Diagnósticos para ver os detalhes."
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func savedReference(_ ref: RuntimeStateStore.WindowRef, matches ids: Set<WindowID>) -> Bool {
        if ids.contains(where: { $0.token == ref.token }) { return true }
        let candidates = windowsByID.values.filter { window in
            if let bundle = ref.bundleID, window.bundleID == bundle {
                return ref.title.isEmpty || window.title == ref.title || ref.title.count < 4
            }
            return ref.bundleID == nil && window.appName == ref.appName && window.title == ref.title
        }
        return candidates.count == 1
    }

    private func approximatelyEqual(_ lhs: Rect, _ rhs: Rect, tolerance: Double) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    private func frameDescription(_ frame: Rect) -> String {
        "x:\(Int(frame.x)) y:\(Int(frame.y)) \(Int(frame.width))×\(Int(frame.height))"
    }
}
