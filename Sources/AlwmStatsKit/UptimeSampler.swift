import Foundation
import Darwin

/// Samples system uptime via `kern.boottime`.
public final class UptimeSampler: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var uptimeSeconds: TimeInterval
        public var bootDate: Date?

        public init(uptimeSeconds: TimeInterval = 0, bootDate: Date? = nil) {
            self.uptimeSeconds = uptimeSeconds
            self.bootDate = bootDate
        }
    }

    public init() {}

    public func sample() -> Snapshot {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else {
            return Snapshot()
        }
        let bootDate = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
        return Snapshot(
            uptimeSeconds: Date().timeIntervalSince(bootDate),
            bootDate: bootDate
        )
    }
}
