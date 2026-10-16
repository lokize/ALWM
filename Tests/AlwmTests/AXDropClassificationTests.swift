import Testing
@testable import Alwm

@Suite("Accessibility drop classification")
struct AXDropClassificationTests {
    @Test("two tiled windows from one workspace trigger recovery protection")
    func sameWorkspaceMassDropIsProtected() {
        #expect(AXDropClassification.isMassDisappear(
            removedTiledWindows: 2,
            forgottenWindows: 0,
            strippedWorkspaceCount: 1
        ))
    }

    @Test("one closed tiled window keeps normal close handling")
    func singleWindowCloseIsNotMassDrop() {
        #expect(!AXDropClassification.isMassDisappear(
            removedTiledWindows: 1,
            forgottenWindows: 0,
            strippedWorkspaceCount: 1
        ))
    }

    @Test("a mass AX drop during a visibility pass is expected churn, not resume recovery")
    func visibilityPassDoesNotArmResumeRecovery() {
        #expect(!AXDropClassification.isMassDisappear(
            removedTiledWindows: 3,
            forgottenWindows: 0,
            strippedWorkspaceCount: 1,
            isApplyingVisibility: true
        ))
    }

    @Test("a mass AX drop during a workspace switch does not start a disk rematch")
    func workspaceTransitionDoesNotArmResumeRecovery() {
        #expect(!AXDropClassification.isMassDisappear(
            removedTiledWindows: 3,
            forgottenWindows: 2,
            strippedWorkspaceCount: 2,
            isWorkspaceTransition: true
        ))
    }
}
