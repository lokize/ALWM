import Testing
@testable import Alwm

@Suite("Workspace visibility reconciliation")
struct WorkspaceVisibilityReconciliationTests {
    @Test("an active workspace tile leak onto another monitor is detected")
    func activeHomeCrossMonitorLeakIsDetected() {
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

    @Test("an active tile leaking from MSI into HDMI is constrained to MSI instead of hidden")
    func activeTileLeakIsConstrainedToItsHomeMonitor() {
        let msi = MonitorInfo(
            id: 2,
            frame: Rect(x: 0, y: 0, width: 3440, height: 1440),
            visibleFrame: Rect(x: 0, y: 0, width: 3440, height: 1410),
            name: "MSI"
        )
        let hdmi = MonitorInfo(
            id: 3,
            frame: Rect(x: 774, y: 1440, width: 1920, height: 1080),
            visibleFrame: Rect(x: 774, y: 1440, width: 1920, height: 1080),
            name: "HDMI"
        )
        let active = [msi.id: "2", hdmi.id: "6"]
        let leaked = Rect(x: 1680, y: 1470, width: 3423, height: 1050)

        let corrected = WorkspaceMonitorLeakPolicy.correctedActiveTileFrame(
            home: "2", frame: leaked, homeBounds: msi.visibleFrame,
            monitors: [msi, hdmi], activeWorkspaceByMonitor: active
        )

        #expect(corrected != nil)
        #expect(corrected?.x == 17)
        #expect(corrected?.y == 360)
        #expect(corrected?.maxX == msi.visibleFrame.maxX)
        #expect(corrected?.maxY == msi.visibleFrame.maxY)
        #expect(corrected.map {
            !WorkspaceMonitorLeakPolicy.frameLeaksWrongMonitor(
                home: "2", frame: $0, monitors: [msi, hdmi], activeWorkspaceByMonitor: active
            )
        } == true)
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
