import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Best-effort window alpha for foreign apps (Quake Terminal/Ghostty) via SkyLight.
enum WindowOpacity {
    @discardableResult
    static func set(cgWindowID: CGWindowID, alpha: Double) -> Bool {
        guard cgWindowID != 0 else { return false }
        let a = Float(min(1, max(0.05, alpha)))
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
            RTLD_LAZY
        ) else {
            NSLog("ALWM Opacity: SkyLight dlopen failed")
            return false
        }
        defer { dlclose(handle) }

        typealias ConnFn = @convention(c) () -> UInt32
        typealias SetAlphaFn = @convention(c) (UInt32, CGWindowID, Float) -> Int32
        typealias GetAlphaFn = @convention(c) (UInt32, CGWindowID, UnsafeMutablePointer<Float>) -> Int32

        guard let connSym = dlsym(handle, "SLSMainConnectionID") ?? dlsym(handle, "CGSMainConnectionID") else {
            return false
        }
        let conn = unsafeBitCast(connSym, to: ConnFn.self)()

        let setNames = ["SLSSetWindowAlpha", "CGSSetWindowAlpha"]
        var setOK = false
        for name in setNames {
            guard let sym = dlsym(handle, name) else { continue }
            let fn = unsafeBitCast(sym, to: SetAlphaFn.self)
            let rc = fn(conn, cgWindowID, a)
            if rc == 0 {
                setOK = true
                break
            }
            NSLog("ALWM Opacity: %@ wid=%u alpha=%.2f rc=%d", name, cgWindowID, a, rc)
        }
        guard setOK else { return false }

        // Verify (some builds report success but leave alpha unchanged).
        for name in ["SLSGetWindowAlpha", "CGSGetWindowAlpha"] {
            guard let sym = dlsym(handle, name) else { continue }
            let fn = unsafeBitCast(sym, to: GetAlphaFn.self)
            var got: Float = -1
            if fn(conn, cgWindowID, &got) == 0 {
                if abs(got - a) < 0.08 { return true }
                NSLog("ALWM Opacity: verify mismatch wid=%u want=%.2f got=%.2f", cgWindowID, a, got)
            }
        }
        // Setter succeeded even if get is missing — treat as OK.
        return true
    }

    /// Resolve a live CGWindowID for `pid`, preferring `preferred` when still listed.
    static func resolveCGWindowID(pid: pid_t, preferred: Int?) -> CGWindowID? {
        let options: [CGWindowListOption] = [
            [.optionOnScreenOnly, .excludeDesktopElements],
            [.excludeDesktopElements],
            []
        ]
        for option in options {
            guard let infos = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] else {
                continue
            }
            var owned: [(CGWindowID, Double)] = []
            for info in infos {
                let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    ?? (info[kCGWindowOwnerPID as String] as? pid_t)
                guard owner == pid else { continue }
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
                    ?? (info[kCGWindowLayer as String] as? Int)
                    ?? 0
                guard layer == 0 else { continue }
                guard let num = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                    ?? (info[kCGWindowNumber as String] as? UInt32)
                    ?? (info[kCGWindowNumber as String] as? Int).map(UInt32.init)
                else { continue }
                if let preferred, Int(num) == preferred { return num }
                let bounds = info[kCGWindowBounds as String] as? [String: Any]
                let w = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
                let h = (bounds?["Height"] as? NSNumber)?.doubleValue ?? 0
                owned.append((num, max(1, w * h)))
            }
            if let best = owned.max(by: { $0.1 < $1.1 })?.0 {
                return best
            }
        }
        return nil
    }

    @discardableResult
    static func set(pid: pid_t, preferredWindowNumber: Int?, alpha: Double) -> Bool {
        let wid = resolveCGWindowID(pid: pid, preferred: preferredWindowNumber)
            ?? preferredWindowNumber.map { CGWindowID($0) }
        guard let wid else {
            NSLog("ALWM Opacity: no CG window for pid=%d", pid)
            return false
        }
        return set(cgWindowID: wid, alpha: alpha)
    }
}
