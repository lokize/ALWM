import Testing
@testable import Alwm

@Suite("New window layout recovery policy")
struct NewWindowLayoutRecoveryPolicyTests {
    @Test("a same-title new window outside recovery uses the normal tile snap")
    func sameTitleWindowDoesNotTriggerRestoreOutsideRecovery() {
        #expect(!NewWindowLayoutRecoveryPolicy.shouldRestore(
            isResumeRecovering: false,
            isResumeWindow: false,
            addedTileCount: 1,
            diskClaimsAddedWindow: true
        ))
    }

    @Test("a saved window returning during startup can still rematch from disk")
    func savedWindowCanRestoreDuringStartup() {
        #expect(NewWindowLayoutRecoveryPolicy.shouldRestore(
            isResumeRecovering: false,
            isResumeWindow: true,
            addedTileCount: 1,
            diskClaimsAddedWindow: true
        ))
    }

    @Test("wake recovery keeps its dedicated layout pass")
    func activeResumeRecoveryDoesNotStartMassRestore() {
        #expect(!NewWindowLayoutRecoveryPolicy.shouldRestore(
            isResumeRecovering: true,
            isResumeWindow: true,
            addedTileCount: 3,
            diskClaimsAddedWindow: true
        ))
    }
}
