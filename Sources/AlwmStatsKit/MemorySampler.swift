import Foundation
import Darwin
import AppKit

/// Samples host memory via `vm_statistics64` + top resident processes.
public final class MemorySampler: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var totalBytes: UInt64
        public var usedBytes: UInt64
        public var appBytes: UInt64
        public var wiredBytes: UInt64
        public var compressedBytes: UInt64
        public var cachedBytes: UInt64
        public var freeBytes: UInt64
        public var swapUsedBytes: UInt64
        public var pressure: Pressure
        public var topProcesses: [ProcessUsage]

        public var usageFraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
        }

        public init(
            totalBytes: UInt64 = 0,
            usedBytes: UInt64 = 0,
            appBytes: UInt64 = 0,
            wiredBytes: UInt64 = 0,
            compressedBytes: UInt64 = 0,
            cachedBytes: UInt64 = 0,
            freeBytes: UInt64 = 0,
            swapUsedBytes: UInt64 = 0,
            pressure: Pressure = .normal,
            topProcesses: [ProcessUsage] = []
        ) {
            self.totalBytes = totalBytes
            self.usedBytes = usedBytes
            self.appBytes = appBytes
            self.wiredBytes = wiredBytes
            self.compressedBytes = compressedBytes
            self.cachedBytes = cachedBytes
            self.freeBytes = freeBytes
            self.swapUsedBytes = swapUsedBytes
            self.pressure = pressure
            self.topProcesses = topProcesses
        }
    }

    public enum Pressure: String, Sendable {
        case normal
        case warn
        case critical
    }

    public struct ProcessUsage: Sendable, Identifiable {
        public var id: Int32 { pid }
        public var pid: Int32
        public var name: String
        public var residentBytes: UInt64
    }

    private let processLimit = 8
    private let pageSize: UInt64

    public init() {
        var ps: vm_size_t = 0
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_size_t>.stride / MemoryLayout<natural_t>.stride
        )
        let kr = host_page_size(mach_host_self(), &ps)
        if kr == KERN_SUCCESS, ps > 0 {
            pageSize = UInt64(ps)
        } else {
            pageSize = 16_384
        }
        _ = count
    }

    public func sample() -> Snapshot {
        let vm = sampleVM()
        let swap = sampleSwap()
        let pressure = pressureLevel(used: vm.used, total: vm.total, swap: swap)
        return Snapshot(
            totalBytes: vm.total,
            usedBytes: vm.used,
            appBytes: vm.app,
            wiredBytes: vm.wired,
            compressedBytes: vm.compressed,
            cachedBytes: vm.cached,
            freeBytes: vm.free,
            swapUsedBytes: swap,
            pressure: pressure,
            topProcesses: sampleTopProcesses()
        )
    }

    // MARK: - VM

    private struct VMParts {
        var total: UInt64
        var used: UInt64
        var app: UInt64
        var wired: UInt64
        var compressed: UInt64
        var cached: UInt64
        var free: UInt64
    }

    private func sampleVM() -> VMParts {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        let total = physicalMemory()
        guard kr == KERN_SUCCESS else {
            return VMParts(total: total, used: 0, app: 0, wired: 0, compressed: 0, cached: 0, free: total)
        }

        let page = pageSize
        let free = UInt64(stats.free_count) * page
        let active = UInt64(stats.active_count) * page
        let inactive = UInt64(stats.inactive_count) * page
        let speculative = UInt64(stats.speculative_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressor = UInt64(stats.compressor_page_count) * page
        let purgeable = UInt64(stats.purgeable_count) * page
        let external = UInt64(stats.external_page_count) * page

        // App ≈ active + inactive + speculative − purgeable (Activity Monitor style approximation).
        let app = active + inactive + speculative
        let cached = purgeable + external
        let used = min(total, wired + compressor + app)
        let freeish = total > used ? total - used : free

        return VMParts(
            total: total,
            used: used,
            app: app,
            wired: wired,
            compressed: compressor,
            cached: cached,
            free: freeish
        )
    }

    private func physicalMemory() -> UInt64 {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return size
    }

    private func sampleSwap() -> UInt64 {
        // `xsw_usage` is not always imported into Swift; mirror the C layout.
        struct SwapUsage {
            var total: UInt64 = 0
            var avail: UInt64 = 0
            var used: UInt64 = 0
            var pagesize: UInt32 = 0
            var encrypted: Int32 = 0
        }
        var xsw = SwapUsage()
        var size = MemoryLayout<SwapUsage>.size
        guard sysctlbyname("vm.swapusage", &xsw, &size, nil, 0) == 0 else { return 0 }
        return xsw.used
    }

    private func pressureLevel(used: UInt64, total: UInt64, swap: UInt64) -> Pressure {
        guard total > 0 else { return .normal }
        let ratio = Double(used) / Double(total)
        if ratio >= 0.92 || swap > total / 8 { return .critical }
        if ratio >= 0.78 || swap > 0 { return .warn }
        return .normal
    }

    // MARK: - Processes

    private func sampleTopProcesses() -> [ProcessUsage] {
        let pids = listPIDs()
        var rows: [ProcessUsage] = []
        rows.reserveCapacity(processLimit * 2)
        for pid in pids {
            guard pid > 0 else { continue }
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.stride)
            let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
            guard result == size else { continue }
            let resident = UInt64(info.pti_resident_size)
            guard resident > 8 * 1024 * 1024 else { continue }
            let name = processName(pid: pid) ?? "pid \(pid)"
            rows.append(ProcessUsage(pid: pid, name: name, residentBytes: resident))
        }
        return rows.sorted { $0.residentBytes > $1.residentBytes }.prefix(processLimit).map { $0 }
    }

    private func listPIDs() -> [Int32] {
        let bufSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufSize > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(bufSize) / MemoryLayout<Int32>.size)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufSize)
        guard filled > 0 else { return [] }
        let count = Int(filled) / MemoryLayout<Int32>.size
        return Array(pids.prefix(count))
    }

    private func processName(pid: Int32) -> String? {
        var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = proc_name(pid, &name, UInt32(name.count))
        guard result > 0 else { return nil }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
