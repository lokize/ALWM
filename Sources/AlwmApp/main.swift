import AppKit
import Alwm

@main
enum ALWMMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var manager: WindowManager?
    private var permissionsGate: PermissionsGateController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register login item before permissions gate — otherwise a first launch that
        // stops at the gate never enables "Open at Login".
        applyLaunchAtLoginPreference()

        let snap = Permissions.snapshot()
        // Tiling can start once required perms exist; capture needs Screen Recording.
        if snap.requiredGranted {
            startManager()
        }
        // Always show the gate when anything is still missing (every launch).
        if !snap.requiredGranted || !snap.screenRecording {
            showPermissionsGate()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.stop()
    }

    private func showPermissionsGate() {
        if permissionsGate != nil {
            permissionsGate?.show()
            return
        }
        let gate = PermissionsGateController()
        gate.onReady = { [weak self] in
            self?.permissionsGate = nil
            let snap = Permissions.snapshot()
            if snap.requiredGranted {
                self?.startManager()
            }
        }
        gate.onQuit = {
            NSApp.terminate(nil)
        }
        permissionsGate = gate
        gate.show()
    }

    private func applyLaunchAtLoginPreference() {
        let store = ConfigStore()
        try? store.load()
        LaunchAtLogin.setEnabled(store.config.settings.launchAtLogin)
    }

    private func startManager() {
        guard manager == nil else { return }
        let manager = WindowManager()
        self.manager = manager
        do {
            try manager.start()
            NSLog(
                "ALWM started (AX=%@ Input=%@ Screen=%@ Mic=%@)",
                Permissions.accessibilityGranted() ? "yes" : "no",
                Permissions.inputMonitoringGranted() ? "yes" : "no",
                Permissions.screenRecordingGranted() ? "yes" : "no",
                Permissions.microphoneGranted() ? "yes" : "no"
            )
        } catch {
            NSLog("ALWM failed to start: \(error)")
            let alert = NSAlert()
            alert.messageText = "ALWM failed to start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }
}
