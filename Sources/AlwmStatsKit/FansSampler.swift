import Foundation
import IOKit
import Darwin

/// Samples fan RPM via AppleSMC (`FNum`, `FiAc` / `FiMn` / `FiMx` / `FiID`).
/// Returns `present == false` on fanless Macs (e.g. many MacBook Airs).
public final class FansSampler: @unchecked Sendable {
    public struct Fan: Sendable, Identifiable {
        public var id: Int
        public var name: String
        public var rpm: Double
        public var minRPM: Double
        public var maxRPM: Double

        public var fraction: Double {
            let span = maxRPM - minRPM
            guard span > 1 else {
                return maxRPM > 0 ? min(max(rpm / maxRPM, 0), 1) : 0
            }
            return min(max((rpm - minRPM) / span, 0), 1)
        }

        public init(id: Int, name: String, rpm: Double, minRPM: Double, maxRPM: Double) {
            self.id = id
            self.name = name
            self.rpm = rpm
            self.minRPM = minRPM
            self.maxRPM = maxRPM
        }
    }

    public struct Snapshot: Sendable {
        public var present: Bool
        public var fans: [Fan]
        public var primaryRPM: Double?
        public var primaryFraction: Double?

        public init(
            present: Bool = false,
            fans: [Fan] = [],
            primaryRPM: Double? = nil,
            primaryFraction: Double? = nil
        ) {
            self.present = present
            self.fans = fans
            self.primaryRPM = primaryRPM
            self.primaryFraction = primaryFraction
        }
    }

    private let smc = SMCReader()

    public init() {}

    public func sample() -> Snapshot {
        guard smc.isOpen, let countValue = smc.doubleValue("FNum") else {
            return Snapshot(present: false)
        }
        let count = Int(countValue.rounded())
        guard count > 0 else {
            return Snapshot(present: false)
        }

        var fans: [Fan] = []
        fans.reserveCapacity(count)
        for i in 0..<count {
            let rpm = smc.doubleValue("F\(i)Ac") ?? 0
            let minRPM = smc.doubleValue("F\(i)Mn") ?? 0
            let maxRPM = smc.doubleValue("F\(i)Mx") ?? max(minRPM + 1, 1)
            let name = smc.stringValue("F\(i)ID") ?? defaultName(index: i, count: count)
            fans.append(Fan(id: i, name: name, rpm: rpm, minRPM: minRPM, maxRPM: maxRPM))
        }

        let fastest = fans.max(by: { $0.rpm < $1.rpm })
        return Snapshot(
            present: true,
            fans: fans,
            primaryRPM: fastest?.rpm,
            primaryFraction: fastest?.fraction
        )
    }

    private func defaultName(index: Int, count: Int) -> String {
        if count == 2 {
            return index == 0 ? "Left fan" : "Right fan"
        }
        return "Fan #\(index)"
    }
}

// MARK: - Minimal read-only AppleSMC client

private final class SMCReader: @unchecked Sendable {
    private var connection: io_connect_t = 0

    var isOpen: Bool { connection != 0 }

    init() {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleSMC")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        let device = IOIteratorNext(iterator)
        guard device != 0 else { return }
        defer { IOObjectRelease(device) }
        _ = IOServiceOpen(device, mach_task_self_, 0, &connection)
    }

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    func doubleValue(_ key: String) -> Double? {
        guard let val = read(key), val.dataSize > 0 else { return nil }
        let size = Int(val.dataSize)
        let bytes = Array(val.bytes.prefix(size))
        if bytes.allSatisfy({ $0 == 0 }), key != "FS! " {
            return nil
        }
        switch val.dataType {
        case "ui8 ":
            return Double(bytes[0])
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(
                UInt32(bytes[0]) << 24
                    | UInt32(bytes[1]) << 16
                    | UInt32(bytes[2]) << 8
                    | UInt32(bytes[3])
            )
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.withUnsafeBytes { $0.load(as: Float.self) })
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int(bytes[0]) * 256 + Int(bytes[1])) / 256.0
        default:
            if size == 1 { return Double(bytes[0]) }
            if size == 2 { return Double((Int(bytes[0]) << 6) + (Int(bytes[1]) >> 2)) }
            if size >= 4 { return Double(bytes.withUnsafeBytes { $0.load(as: Float.self) }) }
            return nil
        }
    }

    func stringValue(_ key: String) -> String? {
        guard let val = read(key), val.dataSize > 0, val.dataType == "{fds" else { return nil }
        let chars = val.bytes[4..<min(16, val.bytes.count)].compactMap { b -> Character? in
            guard b > 0 else { return nil }
            return Character(UnicodeScalar(b))
        }
        let s = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private struct Val {
        var key: String
        var dataSize: UInt32 = 0
        var dataType: String = ""
        var bytes: [UInt8] = Array(repeating: 0, count: 32)
    }

    private struct KeyData {
        struct Vers {
            var major: UInt8 = 0
            var minor: UInt8 = 0
            var build: UInt8 = 0
            var reserved: UInt8 = 0
            var release: UInt16 = 0
        }

        struct LimitData {
            var version: UInt16 = 0
            var length: UInt16 = 0
            var cpuPLimit: UInt32 = 0
            var gpuPLimit: UInt32 = 0
            var memPLimit: UInt32 = 0
        }

        struct KeyInfo {
            var dataSize: IOByteCount32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
        }

        typealias Bytes = (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        )

        var key: UInt32 = 0
        var vers = Vers()
        var pLimitData = LimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )
    }

    private func read(_ key: String) -> Val? {
        guard connection != 0, key.utf8.count == 4 else { return nil }
        var input = KeyData()
        var output = KeyData()
        input.key = fourCharCode(key)
        input.data8 = 9 // readKeyInfo
        guard call(index: 2, input: &input, output: &output) == KERN_SUCCESS else { return nil }

        var val = Val(key: key)
        val.dataSize = UInt32(output.keyInfo.dataSize)
        val.dataType = fourCharString(output.keyInfo.dataType)
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.data8 = 5 // readBytes
        guard call(index: 2, input: &input, output: &output) == KERN_SUCCESS else { return nil }

        var outBytes = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: output.bytes) { raw in
            for i in 0..<min(32, raw.count) {
                outBytes[i] = raw[i]
            }
        }
        val.bytes = outBytes
        return val
    }

    private func call(index: UInt32, input: inout KeyData, output: inout KeyData) -> kern_return_t {
        let inputSize = MemoryLayout<KeyData>.stride
        var outputSize = MemoryLayout<KeyData>.stride
        return IOConnectCallStructMethod(connection, index, &input, inputSize, &output, &outputSize)
    }

    private func fourCharCode(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func fourCharString(_ code: UInt32) -> String {
        let scalars = [
            UnicodeScalar((code >> 24) & 0xff)!,
            UnicodeScalar((code >> 16) & 0xff)!,
            UnicodeScalar((code >> 8) & 0xff)!,
            UnicodeScalar(code & 0xff)!
        ]
        return String(String.UnicodeScalarView(scalars))
    }
}
