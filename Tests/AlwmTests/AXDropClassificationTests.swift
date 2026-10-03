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
}
