import Foundation
import Darwin
import AppKit

/// Samples mounted volumes via `FileManager` and top disk I/O processes via `proc_pid_rusage`.
public final class DiskSampler: @unchecked Sendable {
    public struct Volume: Sendable, Identifiable {
        public var name: String
        public var path: String
        public var totalBytes: UInt64
        public var freeBytes: UInt64
        public var usedBytes: UInt64
        public var isRoot: Bool
        public var isRemovable: Bool
        public var isInternal: Bool
        public var isLocal: Bool

        public var id: String { path }

        public var usageFraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
        }

        public var freeFraction: Double {
            guard totalBytes > 0 else { return 0 }
            return min(max(Double(freeBytes) / Double(totalBytes), 0), 1)
        }

        public init(
            name: String = "—",
            path: String = "",
            totalBytes: UInt64 = 0,
            freeBytes: UInt64 = 0,
            usedBytes: UInt64 = 0,
            isRoot: Bool = false,
            isRemovable: Bool = false,
            isInternal: Bool = false,
            isLocal: Bool = true
        ) {
            self.name = name
            self.path = path
            self.totalBytes = totalBytes
            self.freeBytes = freeBytes
            self.usedBytes = usedBytes
            self.isRoot = isRoot
            self.isRemovable = isRemovable
            self.isInternal = isInternal
            self.isLocal = isLocal
        }
    }

    public struct ProcessUsage: Sendable, Identifiable {
        public var id: Int32 { pid }
        public var pid: Int32
        public var name: String
        public var readBytesPerSecond: Double
        public var writeBytesPerSecond: Double

        public var bytesPerSecond: Double { readBytesPerSecond + writeBytesPerSecond }
    }

    public struct Snapshot: Sendable {
        public var volumes: [Volume]
        public var root: Volume?
        public var topProcesses: [ProcessUsage]

        public var usageFraction: Double { root?.usageFraction ?? 0 }
        public var freeBytes: UInt64 { root?.freeBytes ?? 0 }
        public var usedBytes: UInt64 { root?.usedBytes ?? 0 }
        public var totalBytes: UInt64 { root?.totalBytes ?? 0 }

        public init(
            volumes: [Volume] = [],
            root: Volume? = nil,
            topProcesses: [ProcessUsage] = []
        ) {
            self.volumes = volumes
            self.root = root
            self.topProcesses = topProcesses
        }
    }

    private struct IOCounters {
        var read: UInt64
        var write: UInt64
    }

    private let processLimit = 8
    private var previousIO: [Int32: IOCounters] = [:]
    private var previousSampleAt: Date?

    public init() {}

    public func sample() -> Snapshot {
        let volumes = sampleVolumes()
        let root = volumes.first(where: \.isRoot) ?? volumes.first
        return Snapshot(
            volumes: volumes,
            root: root,
            topProcesses: sampleTopProcesses()
        )
    }

    // MARK: - Volumes

    private func sampleVolumes() -> [Volume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsRootFileSystemKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeIsLocalKey
        ]

        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []

        var volumes: [Volume] = []
        volumes.reserveCapacity(urls.count)

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let isLocal = values.volumeIsLocal ?? true
            // Skip remote / network shares for the main list (keep UI dense like Stats).
            guard isLocal else { continue }

            let total = UInt64(max(values.volumeTotalCapacity ?? 0, 0))
            guard total > 0 else { continue }

            let important = values.volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
            let available = values.volumeAvailableCapacity.map { UInt64(max($0, 0)) }
            let free = important ?? available ?? 0
            let used = total > free ? total - free : 0

            let name = values.volumeName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = (name?.isEmpty == false) ? name! : url.lastPathComponent

            volumes.append(
                Volume(
                    name: display,
                    path: url.path,
                    totalBytes: total,
                    freeBytes: free,
                    usedBytes: used,
                    isRoot: values.volumeIsRootFileSystem ?? false,
                    isRemovable: (values.volumeIsRemovable ?? false) || (values.volumeIsEjectable ?? false),
                    isInternal: values.volumeIsInternal ?? false,
                    isLocal: isLocal
                )
            )
        }

        volumes.sort { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            if a.isInternal != b.isInternal { return a.isInternal }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return volumes
    }

    // MARK: - Processes

    private func sampleTopProcesses() -> [ProcessUsage] {
        let pids = listPIDs()
        let now = Date()
        var current: [Int32: IOCounters] = [:]
        var names: [Int32: String] = [:]
        current.reserveCapacity(pids.count)

        for pid in pids {
            guard pid > 0 else { continue }
            guard let counters = diskIO(for: pid) else { continue }
            current[pid] = counters
            names[pid] = processName(pid: pid) ?? "pid \(pid)"
        }

        defer {
            previousIO = current
            previousSampleAt = now
        }

        guard let previousAt = previousSampleAt, !previousIO.isEmpty else { return [] }
        let elapsed = now.timeIntervalSince(previousAt)
        guard elapsed > 0.2 else { return [] }

        var rows: [ProcessUsage] = []
        rows.reserveCapacity(processLimit * 2)
        for (pid, counters) in current {
            guard let prev = previousIO[pid] else { continue }
            let dRead = counters.read >= prev.read ? counters.read - prev.read : 0
            let dWrite = counters.write >= prev.write ? counters.write - prev.write : 0
            let readRate = Double(dRead) / elapsed
            let writeRate = Double(dWrite) / elapsed
            let total = readRate + writeRate
            // Ignore idle noise (~4 KB/s).
            guard total >= 4_096 else { continue }
            rows.append(
                ProcessUsage(
                    pid: pid,
                    name: names[pid] ?? "pid \(pid)",
                    readBytesPerSecond: readRate,
                    writeBytesPerSecond: writeRate
                )
            )
        }

        return rows.sorted { $0.bytesPerSecond > $1.bytesPerSecond }.prefix(processLimit).map { $0 }
    }

    private func diskIO(for pid: Int32) -> IOCounters? {
        var info = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard rc == 0 else { return nil }
        return IOCounters(read: info.ri_diskio_bytesread, write: info.ri_diskio_byteswritten)
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
