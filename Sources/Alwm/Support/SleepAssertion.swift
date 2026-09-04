import Foundation
import IOKit.pwr_mgt

@MainActor
enum SleepAssertion {
    private static var assertionID: IOPMAssertionID = 0
    private static var active = false

    /// Prevents the Mac from idle-sleeping (display + system) while ALWM holds the assertion.
    static func setPreventSleep(_ enabled: Bool) {
        if enabled {
            guard !active else { return }
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ALWM Prevent Sleep" as CFString,
                &assertionID
            )
            active = result == kIOReturnSuccess
            if !active {
                NSLog("ALWM: failed to create sleep assertion (%d)", result)
            }
        } else if active {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            active = false
        }
    }

    /// Backward-compatible alias.
    static func setPreventDisplaySleep(_ enabled: Bool) {
        setPreventSleep(enabled)
    }
}
