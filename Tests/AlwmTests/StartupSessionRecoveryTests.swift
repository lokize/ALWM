import Testing
@testable import Alwm

@Suite("Startup session recovery")
struct StartupSessionRecoveryTests {
    @Test("startup keeps retrying beyond the first delayed app window scan")
    func retriesAfterAppsExposeWindowsLate() {
        #expect(StartupSessionRecoveryPolicy.retryDelays.contains(12))
        #expect(StartupSessionRecoveryPolicy.retryDelays.last ?? 0 < StartupSessionRecoveryPolicy.eligibilityDuration)
        #expect(StartupSessionRecoveryPolicy.retryDelays.last ?? 0 > 2.5)
    }
}
