import Foundation
import IOKit
import Metal

/// Samples GPU utilization via IOAccelerator `PerformanceStatistics` (+ Metal model hint).
public final class GPUSampler: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var present: Bool
        public var utilization: Double
        public var renderUtilization: Double?
        public var tilerUtilization: Double?
        public var model: String
        public var coreCount: Int?
        public var memoryUsedBytes: UInt64?
        public var memoryAllocatedBytes: UInt64?
        public var aneUtilization: Double?
        public var fps: Double?

        public init(
            present: Bool = false,
            utilization: Double = 0,
            renderUtilization: Double? = nil,
            tilerUtilization: Double? = nil,
            model: String = "—",
            coreCount: Int? = nil,
            memoryUsedBytes: UInt64? = nil,
            memoryAllocatedBytes: UInt64? = nil,
            aneUtilization: Double? = nil,
            fps: Double? = nil
        ) {
            self.present = present
            self.utilization = utilization
            self.renderUtilization = renderUtilization
            self.tilerUtilization = tilerUtilization
            self.model = model
            self.coreCount = coreCount
            self.memoryUsedBytes = memoryUsedBytes
            self.memoryAllocatedBytes = memoryAllocatedBytes
            self.aneUtilization = aneUtilization
            self.fps = fps
        }
    }

    private let metalName: String?

    public init() {
        metalName = MTLCreateSystemDefaultDevice()?.name
    }

    public func sample() -> Snapshot {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else {
            return Snapshot(present: false, model: metalName ?? "—")
        }
        defer { IOObjectRelease(iterator) }

        var best: Snapshot?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let snap = snapshot(from: service) else { continue }
            if let current = best {
                if snap.utilization > current.utilization {
                    best = snap
                }
            } else {
                best = snap
            }
        }

        if var snap = best {
            if snap.model == "—" || snap.model.isEmpty, let metalName {
                snap.model = metalName
            }
            return snap
        }

        // Metal device exists but no accelerator stats (rare) — still show chip with 0%.
        if let metalName {
            return Snapshot(present: true, model: metalName)
        }
        return Snapshot(present: false)
    }

    private func snapshot(from service: io_service_t) -> Snapshot? {
        let model = stringProperty("model", service: service)
            ?? stringProperty("IONameMatched", service: service)
            ?? metalName
            ?? "—"
        let cores = intProperty("gpu-core-count", service: service)

        guard let stats = dictionaryProperty("PerformanceStatistics", service: service) else {
            return Snapshot(present: true, model: model, coreCount: cores)
        }

        let device = percent(stats, keys: ["Device Utilization %", "Device Utilization"])
        let render = percent(stats, keys: ["Renderer Utilization %", "Renderer Utilization"])
        let tiler = percent(stats, keys: ["Tiler Utilization %", "Tiler Utilization"])
        let used = uint64(stats, keys: ["In use system memory", "In use system memory (driver)"])
        let alloc = uint64(stats, keys: ["Alloc system memory", "Allocated system memory"])

        let util = device ?? render ?? tiler ?? 0

        return Snapshot(
            present: true,
            utilization: util,
            renderUtilization: render,
            tilerUtilization: tiler,
            model: model,
            coreCount: cores,
            memoryUsedBytes: used,
            memoryAllocatedBytes: alloc
        )
    }

    private func percent(_ dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            guard let raw = dict[key] else { continue }
            let value: Double?
            if let n = raw as? Double { value = n }
            else if let n = raw as? Int { value = Double(n) }
            else if let n = raw as? NSNumber { value = n.doubleValue }
            else { value = nil }
            if let value {
                // Values are typically 0…100.
                return min(max(value / 100.0, 0), 1)
            }
        }
        return nil
    }

    private func uint64(_ dict: [String: Any], keys: [String]) -> UInt64? {
        for key in keys {
            guard let raw = dict[key] else { continue }
            if let n = raw as? UInt64 { return n }
            if let n = raw as? Int { return UInt64(max(n, 0)) }
            if let n = raw as? NSNumber { return n.uint64Value }
        }
        return nil
    }

    private func dictionaryProperty(_ key: String, service: io_service_t) -> [String: Any]? {
        guard let cf = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return cf
    }

    private func stringProperty(_ key: String, service: io_service_t) -> String? {
        guard let cf = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        else { return nil }
        if let s = cf as? String { return s }
        if let s = cf as? NSString { return s as String }
        return nil
    }

    private func intProperty(_ key: String, service: io_service_t) -> Int? {
        guard let cf = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        else { return nil }
        if let n = cf as? Int { return n }
        if let n = cf as? NSNumber { return n.intValue }
        return nil
    }
}
