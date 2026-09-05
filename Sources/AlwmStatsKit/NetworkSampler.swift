import Foundation
import Darwin

/// Samples primary network interface throughput and addressing via `getifaddrs`.
public final class NetworkSampler: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var interfaceName: String
        public var displayName: String
        public var isUp: Bool
        public var internetReachable: Bool
        public var downloadBytesPerSec: Double
        public var uploadBytesPerSec: Double
        public var totalDownloadBytes: UInt64
        public var totalUploadBytes: UInt64
        public var localIPv4: String?
        public var localIPv6: String?
        public var macAddress: String?
        public var latencyMs: Double?
        public var jitterMs: Double?

        public init(
            interfaceName: String = "—",
            displayName: String = "—",
            isUp: Bool = false,
            internetReachable: Bool = false,
            downloadBytesPerSec: Double = 0,
            uploadBytesPerSec: Double = 0,
            totalDownloadBytes: UInt64 = 0,
            totalUploadBytes: UInt64 = 0,
            localIPv4: String? = nil,
            localIPv6: String? = nil,
            macAddress: String? = nil,
            latencyMs: Double? = nil,
            jitterMs: Double? = nil
        ) {
            self.interfaceName = interfaceName
            self.displayName = displayName
            self.isUp = isUp
            self.internetReachable = internetReachable
            self.downloadBytesPerSec = downloadBytesPerSec
            self.uploadBytesPerSec = uploadBytesPerSec
            self.totalDownloadBytes = totalDownloadBytes
            self.totalUploadBytes = totalUploadBytes
            self.localIPv4 = localIPv4
            self.localIPv6 = localIPv6
            self.macAddress = macAddress
            self.latencyMs = latencyMs
            self.jitterMs = jitterMs
        }
    }

    private struct Counters {
        var inbound: UInt64
        var outbound: UInt64
        var at: Date
    }

    private var previous: [String: Counters] = [:]
    private var preferredName: String?

    public init() {}

    public func sample() -> Snapshot {
        let ifaces = collectInterfaces()
        guard !ifaces.isEmpty else { return Snapshot() }

        let primary = pickPrimary(from: ifaces)
        preferredName = primary.name

        let now = Date()
        var downRate = 0.0
        var upRate = 0.0
        if let prev = previous[primary.name] {
            let dt = now.timeIntervalSince(prev.at)
            if dt > 0.05 {
                let dIn = primary.inbound &- prev.inbound
                let dOut = primary.outbound &- prev.outbound
                // Counter wrap / reset
                if primary.inbound >= prev.inbound {
                    downRate = Double(dIn) / dt
                }
                if primary.outbound >= prev.outbound {
                    upRate = Double(dOut) / dt
                }
            }
        }
        previous[primary.name] = Counters(inbound: primary.inbound, outbound: primary.outbound, at: now)

        return Snapshot(
            interfaceName: primary.name,
            displayName: friendlyName(primary.name),
            isUp: primary.isUp,
            internetReachable: primary.isUp && (primary.ipv4 != nil || primary.ipv6 != nil),
            downloadBytesPerSec: downRate,
            uploadBytesPerSec: upRate,
            totalDownloadBytes: primary.inbound,
            totalUploadBytes: primary.outbound,
            localIPv4: primary.ipv4,
            localIPv6: primary.ipv6,
            macAddress: primary.mac,
            latencyMs: nil,
            jitterMs: nil
        )
    }

    // MARK: - Interfaces

    private struct IFace {
        var name: String
        var isUp: Bool
        var inbound: UInt64
        var outbound: UInt64
        var ipv4: String?
        var ipv6: String?
        var mac: String?
    }

    private func collectInterfaces() -> [IFace] {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(first) }

        var map: [String: IFace] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ptr = cursor {
            let ifa = ptr.pointee
            defer { cursor = ifa.ifa_next }
            guard let cName = ifa.ifa_name else { continue }
            let name = String(cString: cName)
            if name == "lo0" || name.hasPrefix("lo") { continue }

            var entry = map[name] ?? IFace(
                name: name,
                isUp: (Int32(ifa.ifa_flags) & IFF_UP) != 0,
                inbound: 0,
                outbound: 0,
                ipv4: nil,
                ipv6: nil,
                mac: nil
            )
            entry.isUp = entry.isUp || ((Int32(ifa.ifa_flags) & IFF_UP) != 0)

            if let addr = ifa.ifa_addr {
                let family = Int32(addr.pointee.sa_family)
                if family == AF_LINK {
                    if let data = ifa.ifa_data {
                        let ifdata = data.assumingMemoryBound(to: if_data.self).pointee
                        entry.inbound = UInt64(ifdata.ifi_ibytes)
                        entry.outbound = UInt64(ifdata.ifi_obytes)
                    }
                    addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dlPtr in
                        let sdl = dlPtr.pointee
                        guard sdl.sdl_alen == 6 else { return }
                        withUnsafePointer(to: sdl.sdl_data) { dataPtr in
                            let base = UnsafeRawPointer(dataPtr).advanced(by: Int(sdl.sdl_nlen))
                            let bytes = (0..<6).map { base.load(fromByteOffset: $0, as: UInt8.self) }
                            entry.mac = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
                        }
                    }
                } else if family == AF_INET {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        &host,
                        socklen_t(host.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    if result == 0 {
                        entry.ipv4 = String(cString: host)
                    }
                } else if family == AF_INET6 {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let result = getnameinfo(
                        addr,
                        socklen_t(addr.pointee.sa_len),
                        &host,
                        socklen_t(host.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    if result == 0 {
                        let ip = String(cString: host)
                        if !ip.hasPrefix("fe80") {
                            entry.ipv6 = ip
                        } else if entry.ipv6 == nil {
                            entry.ipv6 = ip
                        }
                    }
                }
            }
            map[name] = entry
        }
        return Array(map.values)
    }

    private func pickPrimary(from ifaces: [IFace]) -> IFace {
        if let preferredName,
           let match = ifaces.first(where: { $0.name == preferredName && $0.isUp }) {
            return match
        }
        let priority = ["en0", "en1", "bridge0", "pdp_ip0"]
        for name in priority {
            if let match = ifaces.first(where: { $0.name == name && $0.isUp }) {
                return match
            }
        }
        if let up = ifaces.filter(\.isUp).max(by: { ($0.inbound + $0.outbound) < ($1.inbound + $1.outbound) }) {
            return up
        }
        return ifaces[0]
    }

    private func friendlyName(_ name: String) -> String {
        if name.hasPrefix("en") { return "Wi-Fi (\(name))" }
        if name.hasPrefix("bridge") { return "Thunderbolt Bridge (\(name))" }
        if name.hasPrefix("pdp_ip") { return "Cellular (\(name))" }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") { return "VPN (\(name))" }
        return name
    }
}
