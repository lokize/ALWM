import Foundation

/// Samples mounted volumes via `FileManager` / URL resource values.
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

    public struct Snapshot: Sendable {
        public var volumes: [Volume]
        public var root: Volume?

        public var usageFraction: Double { root?.usageFraction ?? 0 }
        public var freeBytes: UInt64 { root?.freeBytes ?? 0 }
        public var usedBytes: UInt64 { root?.usedBytes ?? 0 }
        public var totalBytes: UInt64 { root?.totalBytes ?? 0 }

        public init(volumes: [Volume] = [], root: Volume? = nil) {
            self.volumes = volumes
            self.root = root
        }
    }

    public init() {}

    public func sample() -> Snapshot {
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

        let root = volumes.first(where: \.isRoot) ?? volumes.first
        return Snapshot(volumes: volumes, root: root)
    }
}
