import Testing
@testable import Alwm

@Suite("AppKit event monitor delivery")
struct AppKitEventMonitorBridgeTests {
    @Test("mouse event bursts enqueue only one pending MainActor callback")
    func coalescesPendingCallbacks() {
        let gate = EventMonitorCoalescingGate()

        #expect(gate.claim())
        for _ in 0..<100 {
            #expect(!gate.claim())
        }
        gate.release()
        #expect(gate.claim())
    }
}
