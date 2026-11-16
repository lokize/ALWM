import Testing
@testable import Alwm

@Suite("Workspace visibility reconciliation")
struct WorkspaceVisibilityReconciliationTests {
    @Test("workspace transitions never minimize app windows to hide them")
    func workspaceTransitionDoesNotMinimizeWindows() {
        #expect(!WorkspaceTransitionParkingPolicy.mayMinimizeLeakingWindow)
    }

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

    @Test("a parked edge strip on its own home monitor is not considered a leak")
    func edgeStripOnHomeMonitorDoesNotLeak() {
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
        // Workspace 2 is active on MSI, Workspace 5 active on HDMI.
        let active = [msi.id: "2", hdmi.id: "5"]
        let clampedOnMSI = Rect(x: 3400, y: 500, width: 40, height: 714)

        #expect(OffscreenParking.isEdgeStrip(clampedOnMSI, monitors: [msi.frame, hdmi.frame]))
        #expect(!WorkspaceMonitorLeakPolicy.frameLeaksWrongMonitor(
            home: "2", frame: clampedOnMSI, monitors: [msi, hdmi], activeWorkspaceByMonitor: active
        ))

        // But if an edge strip from workspace 2 touches HDMI (the wrong monitor), it IS a leak:
        let clampedOnHDMI = Rect(x: 2654, y: 2000, width: 40, height: 500)
        #expect(OffscreenParking.isEdgeStrip(clampedOnHDMI, monitors: [msi.frame, hdmi.frame]))
        #expect(WorkspaceMonitorLeakPolicy.frameLeaksWrongMonitor(
            home: "2", frame: clampedOnHDMI, monitors: [msi, hdmi], activeWorkspaceByMonitor: active
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

    @Test("focus reveal protection does not exempt an active tile from leak correction")
    func focusedActiveTileStillGetsLeakCorrection() {
        #expect(!VisibilityPassPolicy.shouldSkipLeakCorrection(
            isRevealProtected: true,
            isActiveHomeTile: true
        ))
        #expect(VisibilityPassPolicy.shouldSkipLeakCorrection(
            isRevealProtected: true,
            isActiveHomeTile: false
        ))
    }
}
