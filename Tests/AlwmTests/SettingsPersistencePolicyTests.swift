import Testing
@testable import Alwm

@Suite("Settings persistence")
struct SettingsPersistencePolicyTests {
    @Test("closing untouched settings does not write its stale initial snapshot")
    func doesNotFlushUntouchedSnapshot() {
        #expect(!SettingsPersistencePolicy.shouldFlushOnDisappear(hasPendingLocalChanges: false))
    }

    @Test("closing settings flushes a pending local edit")
    func flushesPendingEdit() {
        #expect(SettingsPersistencePolicy.shouldFlushOnDisappear(hasPendingLocalChanges: true))
    }
}
