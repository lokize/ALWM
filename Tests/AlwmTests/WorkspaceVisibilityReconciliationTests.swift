import Testing
@testable import Alwm

@Suite("Workspace visibility reconciliation")
struct WorkspaceVisibilityReconciliationTests {
    @Test("same logical visibility signature still reconciles a window moved by its app")
    func liveFrameDriftRequiresReconciliation() {
        #expect(!VisibilityPassPolicy.shouldSkip(
            signatureMatches: true,
            forceReveal: false,
            needsOrphanRelayout: false,
            liveStateMatchesPlan: false
        ))
    }

    @Test("settled live frames can use the visibility signature fast path")
    func settledStateCanSkip() {
        #expect(VisibilityPassPolicy.shouldSkip(
            signatureMatches: true,
            forceReveal: false,
            needsOrphanRelayout: false,
            liveStateMatchesPlan: true
        ))
    }
}
