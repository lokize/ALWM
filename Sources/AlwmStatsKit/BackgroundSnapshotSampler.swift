import Foundation

/// Runs potentially blocking sampling work away from the caller and coalesces
/// requests until the current sample has been delivered.
public final class BackgroundSnapshotSampler<Value: Sendable>: @unchecked Sendable {
    private let queue: DispatchQueue
    private let completionQueue: DispatchQueue
    private let operation: @Sendable () -> Value
    private let lock = NSLock()
    private var isRunning = false

    public init(
        label: String,
        completionQueue: DispatchQueue = .main,
        operation: @escaping @Sendable () -> Value
    ) {
        self.queue = DispatchQueue(label: label, qos: .utility)
        self.completionQueue = completionQueue
        self.operation = operation
    }

    /// Returns false when a previous request is still sampling or awaiting delivery.
    @discardableResult
    public func request(_ completion: @escaping @Sendable (Value) -> Void) -> Bool {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return false
        }
        isRunning = true
        lock.unlock()

        queue.async { [self] in
            let value = operation()
            completionQueue.async { [self] in
                completion(value)
                lock.lock()
                isRunning = false
                lock.unlock()
            }
        }
        return true
    }
}
