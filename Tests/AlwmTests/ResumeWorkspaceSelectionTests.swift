import CoreGraphics
import Testing
@testable import Alwm

@Suite("Resume workspace selection")
struct ResumeWorkspaceSelectionTests {
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
}
