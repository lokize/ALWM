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
        max(132, 146 * scale)
    }

    public static func iconSide(scale: CGFloat) -> CGFloat {
        max(10, 11 * scale)
    }

    public static func badgeWidth(scale: CGFloat) -> CGFloat {
        max(18, 20 * scale)
    }

    public static func titleWidth(scale: CGFloat) -> CGFloat {
        max(46, 52 * scale)
    }

    public static func subtitleWidth(scale: CGFloat) -> CGFloat {
        max(42, 48 * scale)
    }

    public static func steamThumbWidth(scale: CGFloat) -> CGFloat {
        max(20, 24 * scale)
    }

    public static func steamThumbHeight(scale: CGFloat) -> CGFloat {
        max(9, 10 * scale)
    }

    public static func steamNameWidth(scale: CGFloat) -> CGFloat {
        max(44, 50 * scale)
    }

    public static func steamPriceWidth(scale: CGFloat) -> CGFloat {
        max(36, 40 * scale)
    }

    public static func steamPlusWidth(scale: CGFloat) -> CGFloat {
        max(16, 18 * scale)
    }

    /// Truncate for fixed-width bar labels.
    public static func short(_ text: String, max: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > max, max > 1 else { return t }
        let idx = t.index(t.startIndex, offsetBy: max - 1)
        return String(t[..<idx]) + "…"
    }
}

// MARK: - Click-outside dismiss for floating ALWM chrome

/// Shared mouse monitor so plugin popovers / Settings close when clicking outside.
@MainActor
public enum PluginPanelOutsideClick {
    private static var globalMonitor: Any?
    private static var localMonitor: Any?
    private static weak var watched: NSWindow?
    private static var onDismiss: (() -> Void)?
    private static var generation = 0

    /// True while a plugin/Settings panel is open and watched for outside-click dismiss.
    public static var hasVisiblePanel: Bool {
        guard let window = watched else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    /// Start watching `window`. Closes any previously watched window.
    /// Install is deferred one turn so the opening click does not dismiss immediately.
    /// - Parameter onDismiss: Custom close (e.g. Settings controller). Default: `orderOut`.
    public static func watch(_ window: NSWindow, onDismiss: (() -> Void)? = nil) {
        if let previous = watched, previous !== window, previous.isVisible {
            let previousCallback = self.onDismiss
            tearDownMonitors()
            watched = nil
            self.onDismiss = nil
            if let previousCallback {
                previousCallback()
            } else {
                previous.orderOut(nil)
            }
        } else {
            tearDownMonitors()
        }
        watched = window
        self.onDismiss = onDismiss
        generation += 1
        let gen = generation
        DispatchQueue.main.async {
            guard gen == generation, watched === window, window.isVisible else { return }
            install(generation: gen)
        }
    }

    /// Stop monitoring. If `window` is passed, only stops when it is the active target.
    public static func stop(for window: NSWindow? = nil) {
        if let window, watched !== window { return }
        tearDownMonitors()
        watched = nil
        onDismiss = nil
    }

    private static func tearDownMonitors() {
        generation += 1
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }

    private static func install(generation gen: Int) {
        let dismiss: () -> Void = {
            guard gen == generation, let window = watched, window.isVisible else {
                stop()
                return
            }
            // Keep open while a sheet / modal is up (plugin details, open panels, …).
            if window.attachedSheet != nil { return }
            if NSApp.modalWindow != nil { return }
            let loc = NSEvent.mouseLocation
            // Slight inflate so shadow / edge clicks still count as inside.
            if window.frame.insetBy(dx: -4, dy: -4).contains(loc) { return }
            let callback = onDismiss
            onDismiss = nil
            if let callback {
                callback()
            } else {
                window.orderOut(nil)
            }
            stop()
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { _ in
            Task { @MainActor in dismiss() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { event in
            Task { @MainActor in dismiss() }
            return event
        }
    }
}
