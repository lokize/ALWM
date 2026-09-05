import Foundation
import IOKit
import IOKit.ps

/// Samples internal battery via IOPowerSources / AppleSmartBattery.
public final class BatterySampler: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var present: Bool
        public var percent: Double
        public var isCharging: Bool
        public var isCharged: Bool
        public var isACPowered: Bool
        public var timeToEmptyMinutes: Int?
        public var timeToFullMinutes: Int?
        public var cycleCount: Int?
        public var designCycleCount: Int?
        public var healthPercent: Double?
        public var temperatureCelsius: Double?
        public var currentCapacity: Int?
        public var maxCapacity: Int?
        public var designCapacity: Int?
        public var powerSource: String

        public init(
            present: Bool = false,
            percent: Double = 0,
            isCharging: Bool = false,
            isCharged: Bool = false,
            isACPowered: Bool = false,
            timeToEmptyMinutes: Int? = nil,
            timeToFullMinutes: Int? = nil,
            cycleCount: Int? = nil,
            designCycleCount: Int? = nil,
            healthPercent: Double? = nil,
            temperatureCelsius: Double? = nil,
            currentCapacity: Int? = nil,
            maxCapacity: Int? = nil,
            designCapacity: Int? = nil,
            powerSource: String = "—"
        ) {
            self.present = present
            self.percent = percent
            self.isCharging = isCharging
            self.isCharged = isCharged
            self.isACPowered = isACPowered
            self.timeToEmptyMinutes = timeToEmptyMinutes
            self.timeToFullMinutes = timeToFullMinutes
            self.cycleCount = cycleCount
            self.designCycleCount = designCycleCount
            self.healthPercent = healthPercent
            self.temperatureCelsius = temperatureCelsius
            self.currentCapacity = currentCapacity
            self.maxCapacity = maxCapacity
            self.designCapacity = designCapacity
            self.powerSource = powerSource
        }
    }

    public init() {}

    public func sample() -> Snapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty
        else {
            return Snapshot(present: false)
        }

        // Only internal battery — ignore AC-only / UPS so desktops auto-hide the chip.
        var best: Snapshot?
        for ps in list {
            guard let raw = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            let type = raw[kIOPSTypeKey] as? String
            guard type == kIOPSInternalBatteryType else { continue }
            best = snapshot(from: raw)
            break
        }

        var snap = best ?? Snapshot(present: false)
        if snap.present {
            enrichFromSmartBattery(&snap)
        }
        return snap
    }

    private func snapshot(from info: [String: Any]) -> Snapshot {
        let current = info[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCap = info[kIOPSMaxCapacityKey] as? Int ?? 100
        let percent: Double
        if maxCap > 0 {
            percent = min(max(Double(current) / Double(maxCap), 0), 1)
        } else {
            percent = 0
        }

        let charging = info[kIOPSIsChargingKey] as? Bool ?? false
        let charged = info[kIOPSIsChargedKey] as? Bool ?? false
        let source = info[kIOPSPowerSourceStateKey] as? String ?? "—"
        let ac = source == kIOPSACPowerValue

        let empty = info[kIOPSTimeToEmptyKey] as? Int
        let full = info[kIOPSTimeToFullChargeKey] as? Int
        // IOKit uses -1 for "calculating / unknown".
        let timeEmpty = (empty != nil && empty! >= 0) ? empty : nil
        let timeFull = (full != nil && full! >= 0) ? full : nil

        return Snapshot(
            present: true,
            percent: percent,
            isCharging: charging,
            isCharged: charged,
            isACPowered: ac,
            timeToEmptyMinutes: timeEmpty,
            timeToFullMinutes: timeFull,
            powerSource: source
        )
    }

    private func enrichFromSmartBattery(_ snap: inout Snapshot) {
        let matching = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        if let cycles = intProperty("CycleCount", service: service) {
            snap.cycleCount = cycles
        }
        if let designCycles = intProperty("DesignCycleCount9C", service: service) {
            snap.designCycleCount = designCycles
        }
        if let current = intProperty("CurrentCapacity", service: service) {
            snap.currentCapacity = current
        }
        if let maxCap = intProperty("MaxCapacity", service: service) {
            snap.maxCapacity = maxCap
        }
        if let design = intProperty("DesignCapacity", service: service) {
            snap.designCapacity = design
        }
        if let temp = intProperty("Temperature", service: service) {
            // AppleSmartBattery temperature is typically centi-Celsius (divide by 100).
            snap.temperatureCelsius = Double(temp) / 100.0
        }

        if let maxCap = snap.maxCapacity, let design = snap.designCapacity, design > 0 {
            snap.healthPercent = min(max(Double(maxCap) / Double(design), 0), 1.5)
        } else if let maxCap = snap.maxCapacity, maxCap > 0, maxCap <= 100 {
            // Some machines already report MaxCapacity as percent health-ish.
            snap.healthPercent = Double(maxCap) / 100.0
        }

        if let charging = boolProperty("IsCharging", service: service) {
            snap.isCharging = charging
        }
        if let charged = boolProperty("FullyCharged", service: service) {
            snap.isCharged = charged
        }
        if let ac = boolProperty("ExternalConnected", service: service) {
            snap.isACPowered = ac
        }
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

    private func boolProperty(_ key: String, service: io_service_t) -> Bool? {
        guard let cf = IORegistryEntryCreateCFProperty(
            service,
            key as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        else { return nil }
        if let b = cf as? Bool { return b }
        if let n = cf as? NSNumber { return n.boolValue }
        return nil
    }
}
