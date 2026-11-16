import CoreGraphics
import Foundation

/// Detects states where AX/window data is meaningless or expensive to churn on:
/// the login session is locked, or the displays are asleep. macOS returns a
/// minimal AX tree in those states, which otherwise looks like a mass window close.
enum SessionActivity {
    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    static var areDisplaysAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    static var isLockedOrDisplaysAsleep: Bool {
        // Tests create windows while the real session may be locked/asleep; keep
        // them deterministic.
        if isRunningTests { return false }
        return isScreenLocked || areDisplaysAsleep
    }

    private static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        let name = ProcessInfo.processInfo.processName
        return name.contains("swiftpm-testing-helper") || name.contains("AlwmTests")
    }
}
