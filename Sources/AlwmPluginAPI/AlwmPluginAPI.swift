import AppKit
import Foundation
import AlwmPluginABI

/// Host API version; plugins with a higher `apiVersion` are rejected.
public let alwmPluginAPIVersion: Int = 1

@objc public enum AlwmBarPlacement: Int, Codable, Sendable, CaseIterable, Identifiable {
    case beforeWorkspaces = 0
    case afterWorkspaces = 1
    /// Obsolete — ⌘ chip removed; host maps this to `afterWorkspaces`.
    case afterCommand = 2

    public var id: Int { rawValue }

    public var rawString: String {
        switch self {
        case .beforeWorkspaces: return "beforeWorkspaces"
        case .afterWorkspaces: return "afterWorkspaces"
        case .afterCommand: return "afterCommand"
        }
    }

    public init?(rawString: String) {
        switch rawString {
        case "beforeWorkspaces": self = .beforeWorkspaces
        case "afterWorkspaces": self = .afterWorkspaces
        case "afterCommand": self = .afterCommand
        default: return nil
        }
    }
}

public typealias AlwmPluginCreateFn = alwm_plugin_create_fn

// MARK: - Plugin author helpers

public protocol AlwmPluginContext: AnyObject {
    var barScale: CGFloat { get }
    var localeIdentifier: String { get }
    func requestBarRefresh()
}

public protocol AlwmPlugin: AnyObject {
    var pluginID: String { get }
    func load(context: AlwmPluginContext)
    func unload()
    func barItem(placement: AlwmBarPlacement) -> NSView?
    func barSignature() -> String
}

/// Builds a C vtable from a Swift `AlwmPlugin` for `alwm_plugin_create`.
public enum AlwmPluginExport {
    public static func makeVTable(plugin: AlwmPlugin) -> UnsafeMutablePointer<AlwmPluginVTable> {
        let runtime = Runtime(plugin: plugin)
        let retained = Unmanaged.passRetained(runtime).toOpaque()
        let table = UnsafeMutablePointer<AlwmPluginVTable>.allocate(capacity: 1)
        table.pointee.userData = retained
        table.pointee.apiVersion = Int32(alwmPluginAPIVersion)
        table.pointee.pluginID = runtime.idUTF8
        table.pointee.load = { userData, hostPtr in
            guard let userData, let hostPtr else { return }
            let runtime = Unmanaged<Runtime>.fromOpaque(userData).takeUnretainedValue()
            runtime.attachHost(hostPtr.pointee)
            runtime.plugin.load(context: runtime)
        }
        table.pointee.unload = { userData in
            guard let userData else { return }
            let runtime = Unmanaged<Runtime>.fromOpaque(userData).takeUnretainedValue()
            runtime.plugin.unload()
            runtime.detachHost()
        }
        table.pointee.barItem = { userData, placementRaw in
            guard let userData else { return nil }
            let runtime = Unmanaged<Runtime>.fromOpaque(userData).takeUnretainedValue()
            let placement = AlwmBarPlacement(rawValue: Int(placementRaw)) ?? .afterWorkspaces
            guard let view = runtime.plugin.barItem(placement: placement) else { return nil }
            return Unmanaged.passRetained(view).toOpaque()
        }
        table.pointee.barSignature = { userData in
            guard let userData else { return nil }
            let runtime = Unmanaged<Runtime>.fromOpaque(userData).takeUnretainedValue()
            return runtime.copySignatureUTF8()
        }
        table.pointee.destroy = { userData in
            guard let userData else { return }
            Unmanaged<Runtime>.fromOpaque(userData).release()
        }
        return table
    }

    private final class Runtime: AlwmPluginContext {
        let plugin: AlwmPlugin
        let idUTF8: UnsafePointer<CChar>
        private var host: AlwmHostContextVTable?
        private var signatureCString: UnsafeMutablePointer<CChar>?

        init(plugin: AlwmPlugin) {
            self.plugin = plugin
            self.idUTF8 = UnsafePointer(strdup(plugin.pluginID)!)
        }

        deinit {
            free(UnsafeMutablePointer(mutating: idUTF8))
            signatureCString?.deallocate()
        }

        func attachHost(_ host: AlwmHostContextVTable) {
            self.host = host
        }

        func detachHost() {
            host = nil
        }

        func copySignatureUTF8() -> UnsafePointer<CChar>? {
            let text = plugin.barSignature()
            signatureCString?.deallocate()
            let utf8 = Array(text.utf8CString)
            let buf = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
            buf.initialize(from: utf8, count: utf8.count)
            signatureCString = buf
            return UnsafePointer(buf)
        }

        var barScale: CGFloat {
            guard let host, let fn = host.barScale else { return 1 }
            return CGFloat(fn(host.userData))
        }

        var localeIdentifier: String {
            if let host, let fn = host.localeUTF8, let c = fn(host.userData) {
                return String(cString: c)
            }
            return Locale.current.identifier
        }

        func requestBarRefresh() {
            guard let host, let fn = host.requestBarRefresh else { return }
            fn(host.userData)
        }
    }
}

// MARK: - Fixed-width workspace bar chips (plugins)

/// Shared sizing + rotation timing so plugin chips do not resize the workspace bar.
public enum PluginBarChipLayout {
    /// Seconds between highlight rotations on the menu bar chip.
    public static let cycleInterval: TimeInterval = 7.0

    public static func chipWidth(scale: CGFloat) -> CGFloat {
        max(156, 172 * scale)
    }

    public static func iconSide(scale: CGFloat) -> CGFloat {
        max(11, 12 * scale)
    }

    public static func badgeWidth(scale: CGFloat) -> CGFloat {
        max(22, 24 * scale)
    }

    public static func titleWidth(scale: CGFloat) -> CGFloat {
        max(54, 60 * scale)
    }

    public static func subtitleWidth(scale: CGFloat) -> CGFloat {
        max(50, 56 * scale)
    }

    public static func steamThumbWidth(scale: CGFloat) -> CGFloat {
        max(22, 26 * scale)
    }

    public static func steamThumbHeight(scale: CGFloat) -> CGFloat {
        max(10, 11 * scale)
    }

    public static func steamNameWidth(scale: CGFloat) -> CGFloat {
        max(52, 58 * scale)
    }

    public static func steamPriceWidth(scale: CGFloat) -> CGFloat {
        max(40, 44 * scale)
    }

    public static func steamPlusWidth(scale: CGFloat) -> CGFloat {
        max(18, 20 * scale)
    }

    /// Truncate for fixed-width bar labels.
    public static func short(_ text: String, max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max, max > 1 else { return t }
        let idx = t.index(t.startIndex, offsetBy: max - 1)
        return String(t[..<idx]) + "…"
    }
}
