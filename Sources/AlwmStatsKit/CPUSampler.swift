import Foundation
import Darwin
import AppKit

/// Samples host CPU load, per-core usage, load averages, and top processes.
public final class CPUSampler: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var totalUsage: Double
        public var systemUsage: Double
        public var userUsage: Double
        public var idleUsage: Double
        public var efficiencyUsage: Double
        public var performanceUsage: Double
        public var coreUsages: [Double]
        public var efficiencyCoreCount: Int
        public var performanceCoreCount: Int
        public var load1: Double
        public var load5: Double
        public var load15: Double
        public var uptimeSeconds: TimeInterval
        public var temperatureCelsius: Double?
        public var frequencyAllMHz: Double?
        public var frequencyEfficiencyMHz: Double?
        public var frequencyPerformanceMHz: Double?
        public var topProcesses: [ProcessUsage]

        public init(
            totalUsage: Double = 0,
            systemUsage: Double = 0,
            userUsage: Double = 0,
            idleUsage: Double = 1,
            efficiencyUsage: Double = 0,
            performanceUsage: Double = 0,
            coreUsages: [Double] = [],
            efficiencyCoreCount: Int = 0,
            performanceCoreCount: Int = 0,
            load1: Double = 0,
            load5: Double = 0,
            load15: Double = 0,
            uptimeSeconds: TimeInterval = 0,
            temperatureCelsius: Double? = nil,
            frequencyAllMHz: Double? = nil,
            frequencyEfficiencyMHz: Double? = nil,
            frequencyPerformanceMHz: Double? = nil,
            topProcesses: [ProcessUsage] = []
        ) {
            self.totalUsage = totalUsage
            self.systemUsage = systemUsage
            self.userUsage = userUsage
            self.idleUsage = idleUsage
            self.efficiencyUsage = efficiencyUsage
            self.performanceUsage = performanceUsage
            self.coreUsages = coreUsages
            self.efficiencyCoreCount = efficiencyCoreCount
            self.performanceCoreCount = performanceCoreCount
            self.load1 = load1
            self.load5 = load5
            self.load15 = load15
            self.uptimeSeconds = uptimeSeconds
            self.temperatureCelsius = temperatureCelsius
            self.frequencyAllMHz = frequencyAllMHz
            self.frequencyEfficiencyMHz = frequencyEfficiencyMHz
            self.frequencyPerformanceMHz = frequencyPerformanceMHz
            self.topProcesses = topProcesses
        }
    }

    public struct ProcessUsage: Sendable, Identifiable {
        public var id: Int32 { pid }
        public var pid: Int32
        public var name: String
        public var usage: Double
    }

    private struct TickSet {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    private var previousHost: TickSet?
    private var previousCores: [TickSet] = []
    private var previousProcessCPU: [Int32: Double] = [:]
    private var previousProcessSampleAt: Date?
    private let processLimit = 8

    public init() {}

    public func sample() -> Snapshot {
        let host = sampleHost()
        let cores = sampleCores()
        let loads = sampleLoadAverage()
        let topology = coreTopology()
        let eCount = topology.efficiency
        let pCount = topology.performance

        var eSum = 0.0
        var pSum = 0.0
        for (index, usage) in cores.enumerated() {
            if index < eCount {
                eSum += usage
            } else {
                pSum += usage
            }
        }
        let eUsage = eCount > 0 ? eSum / Double(eCount) : 0
        let pUsage = pCount > 0 ? pSum / Double(pCount) : 0

        return Snapshot(
            totalUsage: host.total,
            systemUsage: host.system,
            userUsage: host.user,
            idleUsage: host.idle,
            efficiencyUsage: eUsage,
            performanceUsage: pUsage,
            coreUsages: cores,
            efficiencyCoreCount: eCount,
            performanceCoreCount: pCount,
            load1: loads.0,
            load5: loads.1,
            load15: loads.2,
            uptimeSeconds: sampleUptime(),
            temperatureCelsius: nil,
            frequencyAllMHz: nil,
            frequencyEfficiencyMHz: nil,
            frequencyPerformanceMHz: nil,
            topProcesses: sampleTopProcesses()
        )
    }

    // MARK: - Host

    private func sampleHost() -> (total: Double, system: Double, user: Double, idle: Double) {
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            return (0, 0, 0, 1)
        }
        let current = TickSet(
            user: info.cpu_ticks.0,
            system: info.cpu_ticks.1,
            idle: info.cpu_ticks.2,
            nice: info.cpu_ticks.3
        )
        defer { previousHost = current }
        guard let previous = previousHost else {
            return (0, 0, 0, 1)
        }
        return usageDelta(previous: previous, current: current)
    }

    private func usageDelta(previous: TickSet, current: TickSet) -> (total: Double, system: Double, user: Double, idle: Double) {
        let user = delta(current.user, previous.user)
        let system = delta(current.system, previous.system)
        let idle = delta(current.idle, previous.idle)
        let nice = delta(current.nice, previous.nice)
        let totalTicks = user + system + idle + nice
        guard totalTicks > 0 else { return (0, 0, 0, 1) }
        let userPct = Double(user + nice) / Double(totalTicks)
        let systemPct = Double(system) / Double(totalTicks)
        let idlePct = Double(idle) / Double(totalTicks)
        return (userPct + systemPct, systemPct, userPct, idlePct)
    }

    private func delta(_ now: UInt32, _ then: UInt32) -> UInt32 {
        now &- then
    }

    // MARK: - Cores

    private func sampleCores() -> [Double] {
        var cpuCount: natural_t = 0
        var cpuInfoArray: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfoArray,
            &cpuInfoCount
        )
        guard kr == KERN_SUCCESS, let cpuInfoArray, cpuCount > 0 else { return [] }
        defer {
            let size = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfoArray), size)
        }

        let stride = Int(CPU_STATE_MAX)
        var current: [TickSet] = []
        current.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * stride
            let user = UInt32(bitPattern: Int32(cpuInfoArray[base + Int(CPU_STATE_USER)]))
            let system = UInt32(bitPattern: Int32(cpuInfoArray[base + Int(CPU_STATE_SYSTEM)]))
            let idle = UInt32(bitPattern: Int32(cpuInfoArray[base + Int(CPU_STATE_IDLE)]))
            let nice = UInt32(bitPattern: Int32(cpuInfoArray[base + Int(CPU_STATE_NICE)]))
            current.append(TickSet(user: user, system: system, idle: idle, nice: nice))
        }

        defer { previousCores = current }
        guard previousCores.count == current.count else {
            return Array(repeating: 0, count: current.count)
        }

        return zip(previousCores, current).map { prev, cur in
            usageDelta(previous: prev, current: cur).total
        }
    }

    private func coreTopology() -> (efficiency: Int, performance: Int) {
        let e = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        let p = sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        if e > 0 || p > 0 {
            return (e, p)
        }
        let n = sysctlInt("hw.logicalcpu") ?? ProcessInfo.processInfo.processorCount
        return (0, n)
    }

    // MARK: - Load / uptime

    private func sampleLoadAverage() -> (Double, Double, Double) {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return (0, 0, 0) }
        return (loads[0], loads[1], loads[2])
    }

    private func sampleUptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
        let bootDate = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
        return Date().timeIntervalSince(bootDate)
    }

    // MARK: - Processes

    private func sampleTopProcesses() -> [ProcessUsage] {
        let pids = listPIDs()
        let now = Date()
        var currentCPU: [Int32: Double] = [:]
        var names: [Int32: String] = [:]

        for pid in pids {
            guard pid > 0 else { continue }
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.stride)
            let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
            guard result == size else { continue }
            let total = Double(info.pti_total_user + info.pti_total_system)
            currentCPU[pid] = total
            names[pid] = processName(pid: pid) ?? "pid \(pid)"
        }

        defer {
            previousProcessCPU = currentCPU
            previousProcessSampleAt = now
        }

        guard let previousAt = previousProcessSampleAt,
              !previousProcessCPU.isEmpty
        else {
            return []
        }

        let elapsed = now.timeIntervalSince(previousAt)
        guard elapsed > 0.05 else { return [] }

        // Mach timebase → seconds for pti_* fields (nanoseconds on modern macOS).
        let ncpu = Double(max(ProcessInfo.processInfo.processorCount, 1))
        var rows: [ProcessUsage] = []
        for (pid, total) in currentCPU {
            guard let prev = previousProcessCPU[pid] else { continue }
            let delta = total - prev
            guard delta >= 0 else { continue }
            let seconds = delta / 1_000_000_000.0
            let usage = min(max(seconds / elapsed / ncpu, 0), 1)
            if usage < 0.005 { continue }
            rows.append(ProcessUsage(pid: pid, name: names[pid] ?? "pid \(pid)", usage: usage))
        }

        return rows.sorted { $0.usage > $1.usage }.prefix(processLimit).map { $0 }
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

    private func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

public enum StatsProcessIcon {
    public static func icon(forProcessName name: String) -> NSImage? {
        let workspace = NSWorkspace.shared
        if let url = workspace.urlForApplication(withBundleIdentifier: name) {
            return workspace.icon(forFile: url.path)
        }
        // Best-effort: match running apps by localized name / executable.
        for app in workspace.runningApplications {
            if app.localizedName == name || app.bundleURL?.deletingPathExtension().lastPathComponent == name {
                if let icon = app.icon { return icon }
                if let path = app.bundleURL?.path {
                    return workspace.icon(forFile: path)
                }
            }
        }
        return nil
    }
}
