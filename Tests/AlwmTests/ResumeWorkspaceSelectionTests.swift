import CoreGraphics
import Testing
@testable import Alwm

@Suite("Resume workspace selection")
struct ResumeWorkspaceSelectionTests {
    @Test("resume rejects a visible tile with the wrong position and size")
    func rejectsDisplacedTileFrame() {
        let expected = Rect(x: 0, y: 30, width: 1_000, height: 700)
        let actual = Rect(x: 80, y: 70, width: 700, height: 560)
        let monitor = Rect(x: 0, y: 0, width: 1_200, height: 800)

        #expect(!ResumeFrameSelection.matches(
            actual: expected,
            expected: expected,
            usable: monitor,
            monitorFrames: [monitor],
            minSize: Size(width: 200, height: 120),
            isMinimized: true
        ))
        #expect(!ResumeFrameSelection.matches(
            actual: actual,
            expected: expected,
            usable: monitor,
            monitorFrames: [monitor],
            minSize: Size(width: 200, height: 120)
        ))
        #expect(ResumeFrameSelection.matches(
            actual: expected,
            expected: expected,
            usable: monitor,
            monitorFrames: [monitor],
            minSize: Size(width: 200, height: 120)
        ))
    }

    @Test("a partly visible scrolling column can finish recovery at its expected frame")
    func acceptsPartlyVisibleScrollingColumn() {
        let monitor = Rect(x: 0, y: 0, width: 1_200, height: 800)
        let expected = Rect(x: 1_100, y: 30, width: 400, height: 700)

        #expect(ResumeFrameSelection.matches(
            actual: expected,
            expected: expected,
            usable: monitor,
            monitorFrames: [monitor],
            minSize: Size(width: 200, height: 120)
        ))
    }

    @Test("an AX mass drop rearms recovery after previous attempts were exhausted")
    @MainActor
    func massDropRearmsRecovery() {
        let manager = WindowManager()
        manager.isBootstrapping = false
        manager.layoutRecoveryAttempts = manager.maxLayoutRecoveryAttempts
        manager.noteAXMassDropForRecovery()
        defer { manager.cancelPendingResumeRecovery() }

        #expect(manager.isResumeRecovering)
        #expect(manager.softPersistProtectMissingTokens)
        #expect(manager.layoutRecoveryAttempts == 0)
    }

    @Test("new windows fall back to the saved app workspace after window-specific homes")
    func selectsSavedBundleWorkspaceAsFallback() {
        let existing: Set<String> = ["1", "2", "3"]

        #expect(InitialWorkspaceSelection.resolve(
            rule: nil,
            sticky: nil,
            savedLayout: nil,
            bundle: "2",
            existing: existing
        ) == "2")
        #expect(InitialWorkspaceSelection.resolve(
            rule: "3",
            sticky: nil,
            savedLayout: nil,
            bundle: "2",
            existing: existing
        ) == "3")
        #expect(InitialWorkspaceSelection.resolve(
            rule: nil,
            sticky: "1",
            savedLayout: "3",
            bundle: "2",
            existing: existing
        ) == "1")
        #expect(InitialWorkspaceSelection.resolve(
            rule: nil,
            sticky: nil,
            savedLayout: nil,
            bundle: "missing",
            existing: existing
        ) == nil)
    }

    @Test("resume keeps the saved home ahead of an app rule for a reappearing window")
    func savedWindowHomeBeatsAppRuleAfterResume() {
        let existing: Set<String> = ["1", "2", "3"]

        #expect(InitialWorkspaceSelection.resolve(
            rule: "3",
            sticky: "1",
            savedLayout: "1",
            bundle: "2",
            active: "2",
            existing: existing
        ) == "1")
    }

    @Test("a new app window uses its saved workspace even when another workspace is active")
    func savedBundleBeatsActiveWorkspace() {
        let existing: Set<String> = ["1", "2", "3"]

        #expect(InitialWorkspaceSelection.resolve(
            rule: nil,
            sticky: nil,
            savedLayout: nil,
            bundle: "2",
            active: "1",
            existing: existing
        ) == "2")
        #expect(InitialWorkspaceSelection.resolve(
            rule: "3",
            sticky: nil,
            savedLayout: nil,
            bundle: "2",
            active: "1",
            existing: existing
        ) == "3")
        #expect(InitialWorkspaceSelection.resolve(
            rule: nil,
            sticky: nil,
            savedLayout: nil,
            bundle: "missing",
            active: "1",
            existing: existing
        ) == "1")
    }

    @Test("resume is not considered complete when a monitor shows the wrong workspace")
    func rejectsWorkspaceSelectionDrift() {
        let active: [CGDirectDisplayID: String] = [2: "1", 7: "5"]
        let expected: [CGDirectDisplayID: String] = [2: "3", 7: "5"]

        #expect(!ResumeWorkspaceSelection.matches(active: active, expected: expected))
    }

    @Test("resume accepts the saved workspace on every connected monitor")
    func acceptsMatchingWorkspaceSelection() {
        let selected: [CGDirectDisplayID: String] = [2: "3", 7: "5"]

        #expect(ResumeWorkspaceSelection.matches(active: selected, expected: selected))
    }

    @Test("saved workspace is selected only when it belongs to that monitor")
    func resolvesPersistedWorkspaceWithinMonitorPool() {
        let existing: Set<String> = ["1", "2", "3", "5"]

        #expect(ResumeWorkspaceSelection.expectedWorkspace(
            allowed: ["1", "2", "3"],
            savedForMonitor: "3",
            savedGlobally: "5",
            existing: existing
        ) == "3")
        #expect(ResumeWorkspaceSelection.expectedWorkspace(
            allowed: ["1", "2", "3"],
            savedForMonitor: "5",
            savedGlobally: "2",
            existing: existing
        ) == "2")
    }

    @Test("workspace recovery finds saved apps missing from the live AX window set")
    func findsMissingSavedWorkspaceWindows() {
        let chatGPT = RuntimeStateStore.WindowRef(
            token: "32701:29930",
            bundleID: "com.openai.codex",
            appName: "ChatGPT",
            title: "ChatGPT"
        )
        let snapshot = RuntimeStateStore.Snapshot(
            bundleWorkspace: ["com.openai.codex": "2"],
            workspaceLayouts: [
                "2": RuntimeStateStore.WorkspaceLayoutSnapshot(
                    columns: [RuntimeStateStore.ColumnSnapshot(windows: [chatGPT])]
                )
            ]
        )

        #expect(WorkspaceWindowRecoveryPolicy.bundleIDs(
            workspaceID: "2",
            snapshot: snapshot
        ) == ["com.openai.codex"])
        #expect(WorkspaceWindowRecoveryPolicy.shouldRescan(
            workspaceID: "2",
            snapshot: snapshot,
            liveWindows: []
        ))
        #expect(WorkspaceWindowRecoveryPolicy.bundleIDs(
            workspaceID: "1",
            snapshot: snapshot
        ).isEmpty)
        let liveChatGPT = ManagedWindow(
            id: WindowID(pid: 32701, windowNumber: 29930),
            title: "ChatGPT",
            bundleID: "com.openai.codex",
            appName: "ChatGPT",
            frame: Rect(x: 0, y: 0, width: 800, height: 600)
        )
        #expect(!WorkspaceWindowRecoveryPolicy.shouldRescan(
            workspaceID: "2",
            snapshot: snapshot,
            liveWindows: [liveChatGPT]
        ))
    }

    @Test("workspace recovery rescans when a saved window token is missing despite another app window")
    func findsMissingSavedWindowWhenSiblingIsLive() {
        let saved = RuntimeStateStore.WindowRef(
            token: "32701:29930",
            bundleID: "com.openai.codex",
            appName: "ChatGPT",
            title: "ChatGPT"
        )
        let snapshot = RuntimeStateStore.Snapshot(workspaceLayouts: [
            "2": RuntimeStateStore.WorkspaceLayoutSnapshot(
                columns: [RuntimeStateStore.ColumnSnapshot(windows: [saved])]
            )
        ])
        let liveSibling = ManagedWindow(
            id: WindowID(pid: 32701, windowNumber: 444),
            title: "Other ChatGPT Window",
            bundleID: "com.openai.codex",
            appName: "ChatGPT",
            frame: Rect(x: 0, y: 0, width: 800, height: 600)
        )

        #expect(WorkspaceWindowRecoveryPolicy.shouldRescan(
            workspaceID: "2",
            snapshot: snapshot,
            liveWindows: [liveSibling]
        ))
    }
}
