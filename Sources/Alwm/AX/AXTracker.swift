import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

// MARK: - AX tracker — lifecycle

public final class AXTracker: @unchecked Sendable {
    public weak var delegate: AXTrackerDelegate?
    var observers: [pid_t: AXObserver] = [:]
    var axWindows: [WindowID: AXWindow] = [:]
    var managed: [WindowID: ManagedWindow] = [:]
    var runLoopSources: [pid_t: CFRunLoopSource] = [:]
    var titleObservedTokens: Set<String> = []
    var scanWorkItem: DispatchWorkItem?
    /// While > 0, ignore AX move/resize/miniaturize (self-caused layout noise).
    var mutationDepth = 0
    var suppressUntil = Date.distantPast
    /// Last scan diagnostics for status / debugging.
    public var lastScanTrusted = false
    public var lastScanAppCount = 0
    public var lastScanRawWindowCount = 0
    public var lastScanAcceptedCount = 0

    public init() {}

    public var isMutating: Bool { mutationDepth > 0 || Date() < suppressUntil }

    /// Run AX writes without triggering rescan storms from Moved/Resized/Miniaturized.
    public func withMutation<T>(_ body: () -> T) -> T {
        mutationDepth += 1
        defer {
            mutationDepth -= 1
            if mutationDepth == 0 {
                suppressUntil = Date().addingTimeInterval(0.35)
            }
        }
        return body()
    }

    public func suppressNotifications(for seconds: TimeInterval) {
        suppressUntil = Date().addingTimeInterval(seconds)
    }

    public static var isTrusted: Bool {
        let opts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    public static func requestTrust() {
        guard !isTrusted else { return }
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    public func start() {
        scanAll()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(pid: app.processIdentifier)
        }
    }

    public func stop() {
        scanWorkItem?.cancel()
        scanWorkItem = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for (pid, observer) in observers {
            if let source = runLoopSources[pid] {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            }
            _ = observer
        }
        observers.removeAll()
        runLoopSources.removeAll()
    }
}

let kAXWindowNumberAttribute = "AXWindowNumber"

