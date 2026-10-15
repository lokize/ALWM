import Testing
@testable import Alwm

@Suite("Workspace visibility reconciliation")
struct WorkspaceVisibilityReconciliationTests {
    @Test("an active workspace tile is still hidden when its frame leaks onto another monitor")
    func activeHomeDoesNotAllowCrossMonitorTileLeak() {
        let msi = MonitorInfo(
            id: 2,
            frame: Rect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: Rect(x: 0, y: 0, width: 1920, height: 1080),
            name: "MSI"
        )
        let hdmi = MonitorInfo(
            id: 3,
            frame: Rect(x: 1920, y: 0, width: 1920, height: 1080),
            visibleFrame: Rect(x: 1920, y: 0, width: 1920, height: 1080),
            name: "HDMI"
        )
        let active = [msi.id: "2", hdmi.id: "6"]
        let clippedWindow = Rect(x: 300, y: 80, width: 2400, height: 900)
        let windowOnHomeMonitor = Rect(x: 300, y: 80, width: 1400, height: 900)

        #expect(WorkspaceMonitorLeakPolicy.frameLeaksWrongMonitor(
            home: "2", frame: clippedWindow, monitors: [msi, hdmi], activeWorkspaceByMonitor: active
        ))
        #expect(!WorkspaceMonitorLeakPolicy.frameLeaksWrongMonitor(
            home: "2", frame: windowOnHomeMonitor, monitors: [msi, hdmi], activeWorkspaceByMonitor: active
        ))
    }

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
