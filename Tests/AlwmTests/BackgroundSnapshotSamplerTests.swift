import Dispatch
import Foundation
import Testing
@testable import AlwmStatsKit

struct BackgroundSnapshotSamplerTests {
    @Test
    func blockedSamplingDoesNotBlockCallerAndDuplicateTicksAreCoalesced() async throws {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let delivered = DispatchExpectation()
        let sampler = BackgroundSnapshotSampler<Int>(label: "test.blocked-sample") {
            started.signal()
            release.wait()
            return 42
        }

        let requestStartedAt = Date()
        let accepted = sampler.request { value in
            delivered.fulfill(value)
        }
        #expect(accepted)
        #expect(Date().timeIntervalSince(requestStartedAt) < 0.1)
        #expect(waitFor(started, timeout: 1))
        #expect(!sampler.request { _ in })

        release.signal()
        let result = await delivered.value
        #expect(result == 42)
    }
}

private func waitFor(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
}

private final class DispatchExpectation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, Never>?
    private var result: Int?

    var value: Int {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }

    func fulfill(_ value: Int) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            result = value
            lock.unlock()
        }
    }
}
