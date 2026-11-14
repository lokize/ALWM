import Foundation
import IOKit.pwr_mgt

@MainActor
enum SleepAssertion {
    private static var systemAssertionID: IOPMAssertionID = 0
    private static var displayAssertionID: IOPMAssertionID = 0
    private static var wantedMode: SleepPreventionMode = .off

    /// Prevents idle system and/or display sleep as selected in ALWM.
    /// Lid close / Apple menu Sleep / low battery still sleep the Mac.
    static func setMode(_ mode: SleepPreventionMode) {
        wantedMode = mode
        ensureAssertions()
    }

    /// Re-create assertions after wake — IOPM can drop them across sleep cycles.
    static func reassertIfNeeded() {
        guard wantedMode != .off else { return }
        // Release first so we don't leak stale IDs if powerd invalidated them.
        releaseAssertions()
        ensureAssertions()
    }

    private static func ensureAssertions() {
        if wantedMode.preventsSystemSleep, systemAssertionID == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ALWM Prevent System Sleep" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                systemAssertionID = id
            } else {
                NSLog("ALWM: failed to create system-sleep assertion (%d)", result)
            }
        } else if !wantedMode.preventsSystemSleep, systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
        }
        if wantedMode.preventsDisplaySleep, displayAssertionID == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ALWM Prevent Display Sleep" as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                displayAssertionID = id
            } else {
                NSLog("ALWM: failed to create display-sleep assertion (%d)", result)
            }
        } else if !wantedMode.preventsDisplaySleep, displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
    }

    private static func releaseAssertions() {
        if systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
        }
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
    }
}
