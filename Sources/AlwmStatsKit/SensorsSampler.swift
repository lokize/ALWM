import Foundation
import IOKit
import CoreFoundation

/// Samples HID temperature sensors (Apple Silicon / PMU) via IOHIDEventSystemClient.
/// Fragile across models — groups by product name heuristics.
public final class SensorsSampler: @unchecked Sendable {
    public enum Group: String, Sendable, CaseIterable, Comparable {
        case cpu = "CPU"
        case gpu = "GPU"
        case pmu = "PMU"
        case battery = "Battery"
        case nand = "NAND"
        case airport = "Airport"
        case ambient = "Ambient"
        case other = "Other"

        public static func < (lhs: Group, rhs: Group) -> Bool {
            order(lhs) < order(rhs)
        }

        private static func order(_ g: Group) -> Int {
            switch g {
            case .cpu: return 0
            case .gpu: return 1
            case .pmu: return 2
            case .battery: return 3
            case .nand: return 4
            case .airport: return 5
            case .ambient: return 6
            case .other: return 7
            }
        }
    }

    public struct Reading: Sendable, Identifiable {
        public var id: String
        public var name: String
        public var celsius: Double
        public var group: Group

        public init(id: String, name: String, celsius: Double, group: Group) {
            self.id = id
            self.name = name
            self.celsius = celsius
            self.group = group
        }
    }

    public struct Snapshot: Sendable {
        public var present: Bool
        public var readings: [Reading]
        /// Representative chip value — hottest CPU die, else hottest valid reading.
        public var primaryCelsius: Double?

        public init(present: Bool = false, readings: [Reading] = [], primaryCelsius: Double? = nil) {
            self.present = present
            self.readings = readings
            self.primaryCelsius = primaryCelsius
        }

        public var grouped: [(Group, [Reading])] {
            let map = Dictionary(grouping: readings, by: \.group)
            return Group.allCases.compactMap { g in
                guard let list = map[g], !list.isEmpty else { return nil }
                return (g, list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
            }
        }
    }

    public init() {}

    public func sample() -> Snapshot {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            return Snapshot(present: false)
        }
        // Create returns +1.
        defer { Unmanaged<CFTypeRef>.fromOpaque(client).release() }

        let matching: [String: Any] = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 5
        ]
        IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)

        guard let cfServices = IOHIDEventSystemClientCopyServices(client)?.takeRetainedValue() else {
            return Snapshot(present: false)
        }
        let services = cfServices as [AnyObject]
        guard !services.isEmpty else {
            return Snapshot(present: false)
        }

        var readings: [Reading] = []
        readings.reserveCapacity(services.count)

        for (index, serviceObj) in services.enumerated() {
            let service = Unmanaged.passUnretained(serviceObj).toOpaque()
            let product = copyStringProperty(service, "Product") ?? "Sensor \(index + 1)"
            let location = copyNumberProperty(service, "LocationID").map { String($0) } ?? "\(index)"

            // CopyEvent returns +1 — takeRetainedValue hands ownership to ARC (do NOT manual release).
            guard let event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0)?
                .takeRetainedValue()
            else {
                continue
            }
            let value = IOHIDEventGetFloatValue(event, kIOHIDEventFieldTemperatureLevel)
            guard value.isFinite, value > -15, value < 125 else { continue }

            readings.append(
                Reading(
                    id: "\(location):\(product)",
                    name: Self.displayName(product),
                    celsius: value,
                    group: Self.classify(product)
                )
            )
        }

        var seen = Set<String>()
        readings = readings.filter { r in
            let key = "\(r.group.rawValue)|\(r.name)|\(Int(r.celsius.rounded()))"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }

        let cpuMax = readings.filter { $0.group == .cpu }.map(\.celsius).max()
        let anyMax = readings.map(\.celsius).max()
        return Snapshot(
            present: !readings.isEmpty,
            readings: readings,
            primaryCelsius: cpuMax ?? anyMax
        )
    }

    private static func classify(_ product: String) -> Group {
        let p = product.lowercased()
        if p.contains("battery") || p.contains("gas gauge") { return .battery }
        if p.contains("nand") { return .nand }
        if p.contains("airport") || p.contains("wifi") || p.contains("wlan") { return .airport }
        if p.contains("als") { return .ambient }
        if p.contains("gpu") || p.contains("agx") { return .gpu }
        if p.contains("tdie") || p.contains("cpu") || p.contains("soc") { return .cpu }
        if p.contains("pmu") || p.contains("tdev") || p.contains("tcal") { return .pmu }
        return .other
    }

    private static func displayName(_ product: String) -> String {
        product
            .replacingOccurrences(of: "gas gauge battery", with: "Battery", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func copyStringProperty(_ service: UnsafeMutableRawPointer, _ key: String) -> String? {
        guard let raw = IOHIDServiceClientCopyProperty(service, key as CFString)?.takeRetainedValue() else {
            return nil
        }
        return raw as? String
    }

    private func copyNumberProperty(_ service: UnsafeMutableRawPointer, _ key: String) -> Int64? {
        guard let raw = IOHIDServiceClientCopyProperty(service, key as CFString)?.takeRetainedValue() else {
            return nil
        }
        if let n = raw as? NSNumber { return n.int64Value }
        return nil
    }
}

// MARK: - Private IOHID symbols (linked via IOKit)

private let kIOHIDEventTypeTemperature: Int64 = 15
private let kIOHIDEventFieldTemperatureLevel: Int32 = 15 << 16

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> UnsafeMutableRawPointer?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: UnsafeMutableRawPointer?, _ matching: CFDictionary?)

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: UnsafeMutableRawPointer?) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(
    _ service: UnsafeMutableRawPointer?,
    _ key: CFString
) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(
    _ service: UnsafeMutableRawPointer?,
    _ type: Int64,
    _ options: IOOptionBits,
    _ timestamp: Int64
) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: CFTypeRef?, _ field: Int32) -> Double
