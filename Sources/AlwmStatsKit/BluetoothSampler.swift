import Foundation
import IOKit
import IOBluetooth

/// Samples paired/connected Bluetooth devices and battery levels
/// (Apple HID + `system_profiler` for headsets like Soundcore that only report via HFP).
public final class BluetoothSampler: @unchecked Sendable {
    public struct Device: Sendable, Identifiable {
        public var id: String { address }
        public var name: String
        public var address: String
        public var isConnected: Bool
        public var isPaired: Bool
        public var batteryPercent: Double?
        public var category: String?
        public var rssi: Int?

        public init(
            name: String,
            address: String,
            isConnected: Bool = false,
            isPaired: Bool = false,
            batteryPercent: Double? = nil,
            category: String? = nil,
            rssi: Int? = nil
        ) {
            self.name = name
            self.address = BluetoothSampler.normalizeAddress(address)
            self.isConnected = isConnected
            self.isPaired = isPaired
            self.batteryPercent = batteryPercent
            self.category = category
            self.rssi = rssi
        }
    }

    public struct Snapshot: Sendable {
        public var present: Bool
        public var poweredOn: Bool
        public var devices: [Device]
        /// Lowest battery among connected devices that report one (0…1).
        public var primaryBattery: Double?

        public init(
            present: Bool = false,
            poweredOn: Bool = false,
            devices: [Device] = [],
            primaryBattery: Double? = nil
        ) {
            self.present = present
            self.poweredOn = poweredOn
            self.devices = devices
            self.primaryBattery = primaryBattery
        }

        public var connected: [Device] { devices.filter(\.isConnected) }
        public var disconnected: [Device] { devices.filter { !$0.isConnected } }
    }

    private let cacheLock = NSLock()
    private var profilerCache: [String: BatteryInfo] = [:]
    private var profilerCacheAt: Date = .distantPast
    private let profilerCacheTTL: TimeInterval = 8

    public init() {}

    public func sample() -> Snapshot {
        // Prefer IOKit HID + prefs cache first; IOBluetooth pairedDevices() requires
        // NSBluetoothAlwaysUsageDescription in the host Info.plist (TCC kills otherwise).
        let poweredOn = isBluetoothPoweredOn()
        guard poweredOn else {
            return Snapshot(present: false, poweredOn: false)
        }

        let batteries = batteryIndex()
        var devices: [Device] = []

        if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
            for device in paired {
                let address = Self.normalizeAddress(device.addressString ?? "")
                guard !address.isEmpty else { continue }
                let connected = device.isConnected()
                let rssiRaw = Int(device.rawRSSI())
                // 127 = unavailable; 0 is common garbage when the link doesn't report RSSI.
                let rssi = (!connected || rssiRaw == 127 || rssiRaw == 0) ? nil : rssiRaw
                let bat = batteries[address]
                devices.append(
                    Device(
                        name: device.nameOrAddress ?? address,
                        address: address,
                        isConnected: connected,
                        isPaired: device.isPaired(),
                        batteryPercent: bat?.percent,
                        category: bat?.category,
                        rssi: rssi
                    )
                )
            }
        }

        // HID / profiler devices with battery that aren't in the paired list yet.
        for (address, info) in batteries where !devices.contains(where: { $0.address == address }) {
            devices.append(
                Device(
                    name: info.name,
                    address: address,
                    isConnected: true,
                    isPaired: true,
                    batteryPercent: info.percent,
                    category: info.category
                )
            )
        }

        devices.sort { a, b in
            if a.isConnected != b.isConnected { return a.isConnected }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }

        let primary = devices
            .filter { $0.isConnected }
            .compactMap(\.batteryPercent)
            .min()

        return Snapshot(
            present: true,
            poweredOn: true,
            devices: devices,
            primaryBattery: primary
        )
    }

    private struct BatteryInfo {
        var name: String
        var percent: Double
        var category: String?
    }

    private func batteryIndex() -> [String: BatteryInfo] {
        var map: [String: BatteryInfo] = [:]

        for dict in fetchIOService("AppleDeviceManagementHIDEventService") {
            guard let percentRaw = intValue(dict["BatteryPercent"]) else { continue }
            let name = dict["Product"] as? String ?? "Bluetooth device"
            let address = addressFromIO(dict)
            guard !address.isEmpty else { continue }
            let category = dict["Accessory Category"] as? String
            map[address] = BatteryInfo(
                name: name,
                percent: min(max(Double(percentRaw) / 100.0, 0), 1),
                category: category
            )
        }

        // Apple Bluetooth preferences cache (AirPods left/right/case, etc.).
        // Read the plist file — UserDefaults(suiteName: "/path/…") is unreliable.
        let plistURL = URL(fileURLWithPath: "/Library/Preferences/com.apple.Bluetooth.plist")
        if let root = NSDictionary(contentsOf: plistURL) as? [String: Any],
           let deviceCache = root["DeviceCache"] as? [String: [String: Any]],
           let paired = root["PairedDevices"] as? [String]
        {
            for addressRaw in paired {
                let address = Self.normalizeAddress(addressRaw)
                guard let dict = deviceCache[addressRaw] ?? deviceCache[address] else { continue }
                let levels = [
                    dict["BatteryPercent"],
                    dict["BatteryPercentCase"],
                    dict["BatteryPercentLeft"],
                    dict["BatteryPercentRight"]
                ].compactMap(parseBatteryValue)
                guard let minLevel = levels.min() else { continue }
                let name = (dict["Name"] as? String) ?? map[address]?.name ?? address
                mergeBattery(&map, address: address, name: name, percent: minLevel, category: nil)
            }
        }

        // Headsets / third-party accessories (Soundcore, etc.) often only expose
        // battery via the same source as System Settings → Bluetooth.
        for (address, info) in profilerBatteryIndex() {
            mergeBattery(
                &map,
                address: address,
                name: info.name,
                percent: info.percent,
                category: info.category
            )
        }

        return map
    }

    private func mergeBattery(
        _ map: inout [String: BatteryInfo],
        address: String,
        name: String,
        percent: Double,
        category: String?
    ) {
        if let existing = map[address] {
            map[address] = BatteryInfo(
                name: existing.name.isEmpty ? name : existing.name,
                percent: min(existing.percent, percent),
                category: existing.category ?? category
            )
        } else {
            map[address] = BatteryInfo(name: name, percent: percent, category: category)
        }
    }

    /// Batteries from `system_profiler SPBluetoothDataType` (includes HFP headsets).
    private func profilerBatteryIndex() -> [String: BatteryInfo] {
        cacheLock.lock()
        let age = Date().timeIntervalSince(profilerCacheAt)
        if age < profilerCacheTTL, !profilerCache.isEmpty {
            let cached = profilerCache
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let fresh = fetchProfilerBatteries()
        cacheLock.lock()
        profilerCache = fresh
        profilerCacheAt = Date()
        cacheLock.unlock()
        return fresh
    }

    private func fetchProfilerBatteries() -> [String: BatteryInfo] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        proc.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return [:]
        }

        // Don't hang the app if system_profiler stalls (seen under heavy BT load).
        let deadline = Date().addingTimeInterval(2.5)
        while proc.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning {
            proc.terminate()
            _ = proc.waitUntilExit()
            return [:]
        }

        guard proc.terminationStatus == 0 else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [:] }

        var map: [String: BatteryInfo] = [:]
        for section in sections {
            for listKey in ["device_connected", "device_not_connected"] {
                guard let list = section[listKey] as? [[String: Any]] else { continue }
                for entry in list {
                    // Each entry is { "Device Name": { device_address, device_batteryLevelMain, … } }
                    for (name, raw) in entry {
                        guard let props = raw as? [String: Any] else { continue }
                        let address = Self.normalizeAddress(props["device_address"] as? String ?? "")
                        guard !address.isEmpty else { continue }
                        let levels = [
                            props["device_batteryLevelMain"],
                            props["device_batteryLevel"],
                            props["device_batteryLevelLeft"],
                            props["device_batteryLevelRight"],
                            props["device_batteryLevelCase"]
                        ].compactMap(parseBatteryValue)
                        guard let minLevel = levels.min() else { continue }
                        let category = props["device_minorType"] as? String
                        mergeBattery(
                            &map,
                            address: address,
                            name: name,
                            percent: minLevel,
                            category: category
                        )
                    }
                }
            }
        }
        return map
    }

    private func isBluetoothPoweredOn() -> Bool {
        if let controller = IOBluetoothHostController.default() {
            return controller.powerState == kBluetoothHCIPowerStateON
        }
        // Controller missing — still allow HID battery discovery.
        return true
    }

    private func fetchIOService(_ name: String) -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [[String: Any]] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any]
            else { continue }
            result.append(dict)
        }
        return result
    }

    private func addressFromIO(_ dict: [String: Any]) -> String {
        if let s = dict["DeviceAddress"] as? String, !s.isEmpty {
            return Self.normalizeAddress(s)
        }
        if let data = dict["BD_ADDR"] as? Data, data.count >= 6 {
            return data.prefix(6).map { String(format: "%02x", $0) }.joined(separator: "-")
        }
        if let s = dict["SerialNumber"] as? String, !s.isEmpty {
            return Self.normalizeAddress(s)
        }
        return ""
    }

    private func intValue(_ raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let n = raw as? NSNumber { return n.intValue }
        return nil
    }

    private func parseBatteryValue(_ raw: Any?) -> Double? {
        switch raw {
        case let v as Int:
            // Some caches store 0…1 as 0/1 only — treat 0…1 exclusive of 0 as fraction.
            if v == 0 { return 0 }
            if v == 1 { return 1 }
            if v > 1 { return min(Double(v) / 100.0, 1) }
            return Double(v)
        case let v as Double:
            if v <= 1 { return min(max(v, 0), 1) }
            return min(max(v / 100.0, 0), 1)
        case let v as String:
            let trimmed = v.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
            guard let n = Double(trimmed) else { return nil }
            return n <= 1 ? min(max(n, 0), 1) : min(max(n / 100.0, 0), 1)
        default:
            return nil
        }
    }

    public static func normalizeAddress(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "-")
            .lowercased()
    }
}
