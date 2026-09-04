import Foundation
import ServiceManagement

/// Registers ALWM as a Login Item via `SMAppService` (macOS 13+), with a LaunchAgent
/// fallback when SMAppService fails (common with ad-hoc / local signing).
@MainActor
public enum LaunchAtLogin {
    private static let launchAgentLabel = "dev.alwm.ALWM"

    private static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    /// Apply the desired Login Item state. No-op outside an app bundle.
    public static func setEnabled(_ enabled: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            NSLog("ALWM: launch at login skipped (not running from .app bundle)")
            return
        }

        if enabled {
            if tryRegisterSMAppService() {
                removeLaunchAgentFallback()
                return
            }
            installLaunchAgentFallback()
        } else {
            unregisterSMAppService()
            removeLaunchAgentFallback()
        }
    }

    public static var isEnabled: Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        if SMAppService.mainApp.status == .enabled { return true }
        return FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    @discardableResult
    private static func tryRegisterSMAppService() -> Bool {
        let service = SMAppService.mainApp
        do {
            if service.status != .enabled {
                try service.register()
            }
            NSLog("ALWM: launch at login via SMAppService (status=%@)", statusLabel(service.status))
            return true
        } catch {
            NSLog(
                "ALWM: SMAppService register failed (%@) — will try LaunchAgent fallback",
                error.localizedDescription
            )
            return false
        }
    }

    private static func unregisterSMAppService() {
        let service = SMAppService.mainApp
        guard service.status == .enabled else { return }
        do {
            try service.unregister()
            NSLog("ALWM: launch at login disabled (SMAppService)")
        } catch {
            NSLog("ALWM: SMAppService unregister failed: %@", error.localizedDescription)
        }
    }

    private static func installLaunchAgentFallback() {
        let executable = Bundle.main.executableURL?.path
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ALWM").path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            NSLog("ALWM: LaunchAgent fallback skipped — executable not found at %@", executable)
            return
        }

        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]

        do {
            let agentsDir = launchAgentURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: launchAgentURL, options: .atomic)
            _ = shell("/bin/launchctl", "bootout", "gui/\(getuid())/\(launchAgentLabel)")
            let loadRC = shell("/bin/launchctl", "bootstrap", "gui/\(getuid())", launchAgentURL.path)
            if loadRC == 0 {
                NSLog("ALWM: launch at login via LaunchAgent → %@", launchAgentURL.path)
            } else {
                // launchctl bootstrap may fail if already loaded — still OK if plist exists.
                NSLog("ALWM: LaunchAgent plist written (launchctl rc=%d)", loadRC)
            }
        } catch {
            NSLog("ALWM: LaunchAgent fallback failed: %@", error.localizedDescription)
        }
    }

    private static func removeLaunchAgentFallback() {
        _ = shell("/bin/launchctl", "bootout", "gui/\(getuid())/\(launchAgentLabel)")
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    @discardableResult
    private static func shell(_ launchPath: String, _ args: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private static func statusLabel(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
}
