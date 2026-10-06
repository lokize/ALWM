import ApplicationServices
import Foundation
import Testing
@testable import Alwm

@Suite("Accessibility structural scan scheduling")
struct AXTrackerScanSchedulingTests {
    @Test("a transient AX query failure preserves that running app's previous window")
    func keepsWindowsForRunningAppsWithFailedQueries() {
        let chatGPT = WindowID(pid: 32701, windowNumber: 29930)
        let safari = WindowID(pid: 69155, windowNumber: 31602)

        #expect(AXScanRetentionPolicy.retainedWindowIDs(
            previousWindowIDs: [chatGPT, safari],
            unavailablePIDs: [32701],
            runningPIDs: [32701, 69155]
        ) == [chatGPT])
        #expect(AXScanRetentionPolicy.retainedWindowIDs(
            previousWindowIDs: [chatGPT],
            unavailablePIDs: [],
            runningPIDs: [32701]
        ).isEmpty)
        #expect(AXScanRetentionPolicy.retainedWindowIDs(
            previousWindowIDs: [chatGPT],
            unavailablePIDs: [32701],
            runningPIDs: []
        ).isEmpty)
    }

    @Test("window creation during layout mutation still schedules discovery")
    func createdWindowDuringMutationSchedulesScan() {
        let tracker = AXTracker()
        tracker.suppressNotifications(for: 1)

        tracker.handle(
            notification: kAXWindowCreatedNotification as String,
            element: AXUIElementCreateApplication(getpid())
        )

        #expect(tracker.scanWorkItem != nil)
        tracker.stop()
    }

    @Test("a scan delayed by layout suppression eventually runs")
    func deferredScanRunsAfterSuppression() async throws {
        let tracker = AXTracker()
        tracker.lastScanAppCount = -1
        tracker.suppressNotifications(for: 0.4)
        tracker.scheduleScanAll(delay: 0.01)

        for _ in 0..<100 {
            if tracker.lastScanAppCount >= 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(tracker.lastScanAppCount >= 0)
        tracker.stop()
    }
}
