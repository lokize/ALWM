import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

public final class AXWindow: @unchecked Sendable {
    public let id: WindowID
    public let element: AXUIElement
    public let pid: pid_t

    public init(id: WindowID, element: AXUIElement, pid: pid_t) {
        self.id = id
        self.element = element
        self.pid = pid
    }

    public var title: String {
        resolvedTitle()
    }

    /// Electron / VS Code / Cursor often leave AXTitle empty — fall back to description,
    /// document path basename, TitleUIElement, then CGWindowList name.
    public func resolvedTitle() -> String {
        if let s = stringAttribute(kAXTitleAttribute as CFString), !s.isEmpty { return s }
        if let s = stringAttribute(kAXDescriptionAttribute as CFString), !s.isEmpty { return s }
        if let s = stringAttribute("AXDocument" as CFString), !s.isEmpty {
            return (s as NSString).lastPathComponent
        }
        if let titleEl = titleUIElement(),
           let s = Self.stringAttribute(on: titleEl, kAXTitleAttribute as CFString)
            ?? Self.stringAttribute(on: titleEl, kAXValueAttribute as CFString),
           !s.isEmpty {
            return s
        }
        if let cg = Self.cgWindowName(windowNumber: id.windowNumber), !cg.isEmpty {
            return cg
        }
        return ""
    }

    private func stringAttribute(_ attr: CFString) -> String? {
        Self.stringAttribute(on: element, attr)
    }

    private static func stringAttribute(on element: AXUIElement, _ attr: CFString) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attr, &value) == .success,
              let s = value as? String
        else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func titleUIElement() -> AXUIElement? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXTitleUIElementAttribute as CFString, &value) == .success
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func cgWindowName(windowNumber: Int) -> String? {
        guard windowNumber > 0,
              let infos = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]],
              let info = infos.first,
              let name = info[kCGWindowName as String] as? String
        else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var role: String {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
              let s = value as? String else { return "" }
        return s
    }

    public var subrole: String {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success,
              let s = value as? String else { return "" }
        return s
    }

    public var isMinimized: Bool {
        get {
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value) == .success,
                  let b = AXBridge.bool(value) else { return false }
            return b
        }
        set {
            AXUIElementSetAttributeValue(
                element,
                kAXMinimizedAttribute as CFString,
                newValue ? kCFBooleanTrue : kCFBooleanFalse
            )
        }
    }

    public var frame: Rect {
        get {
            var posValue: AnyObject?
            var sizeValue: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
                  AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success
            else {
                return Rect(x: 0, y: 0, width: 0, height: 0)
            }
            var point = CGPoint.zero
            var size = CGSize.zero
            // AXValue is a CFType — Swift `as?` always succeeds; trust the AX attribute types.
            AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
            return Rect(x: point.x, y: point.y, width: size.width, height: size.height)
        }
        set {
            // Electron apps often clamp if position is set before size; size→pos→size is reliable.
            var point = CGPoint(x: newValue.x, y: newValue.y)
            var size = CGSize(width: newValue.width, height: newValue.height)
            if let sz = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sz)
            }
            if let pos = AXValueCreate(.cgPoint, &point) {
                AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pos)
            }
            if let sz = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sz)
            }
        }
    }

    public func focus() {
        // Prefer deminiaturize only after the caller placed geometry (reveal). When we
        // deminiaturize here at park/dock size, macOS clamps a tiny edge strip on-screen.
        if isMinimized {
            let f = frame
            if f.width >= 120, f.height >= 80 {
                isMinimized = false
            }
        }
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        // Last resort: still raise even from a tiny frame (caller should have revealed).
        if isMinimized { isMinimized = false }
    }

    /// Presses the window's close button (same as clicking the red traffic light).
    @discardableResult
    public func close() -> Bool {
        var buttonObj: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &buttonObj) == .success,
              let button = buttonObj
        else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Accept real app windows; skip system dialogs and tiny junk.
    public var isStandardWindow: Bool {
        let r = role
        guard r == (kAXWindowRole as String) || r == "AXWindow" else { return false }
        let s = subrole
        if s == (kAXSystemDialogSubrole as String) || s == "AXSystemDialog" { return false }
        // Standard app windows stay tracked even when miniaturized — AX often reports
        // ~100×30 dock thumbnails (Ghostty/Terminal), which used to drop them entirely
        // and broke Quake adopt/show.
        if s == (kAXStandardWindowSubrole as String) || s == "AXStandardWindow" {
            return true
        }
        let f = frame
        if f.width > 0, f.height > 0, (f.width < 40 || f.height < 40) { return false }
        return true
    }

    /// Open/save panels, sheets, and utility floats should not enter tiling columns.
    public var prefersFloating: Bool {
        if isModal { return true }
        switch subrole {
        case String(kAXDialogSubrole), "AXDialog",
             String(kAXFloatingWindowSubrole), "AXFloatingWindow",
             String(kAXSystemFloatingWindowSubrole), "AXSystemFloatingWindow":
            return true
        default:
            return false
        }
    }

    public var isModal: Bool {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXModalAttribute as CFString, &value) == .success,
              let b = AXBridge.bool(value) else { return false }
        return b
    }
}

public protocol AXTrackerDelegate: AnyObject {
    func axTrackerDidUpdateWindows(_ windows: [ManagedWindow], axWindows: [WindowID: AXWindow])
    func axTrackerFocusedWindowDidChange(_ id: WindowID?)
    /// Title-only update (Electron/tab apps) — must not trigger full ingest.
    func axTrackerWindowTitleDidChange(_ id: WindowID, window: ManagedWindow)
    /// External (or user) move/resize of a tracked window — enforce tiled layout if drifted.
    func axTrackerWindowGeometryChanged(_ id: WindowID)
    /// Window element destroyed (user clicked the red X) — handle before soft-delete lag.
    func axTrackerWindowDidClose(_ id: WindowID)
}

enum AXBridge {
    static func int(_ value: AnyObject?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    static func bool(_ value: AnyObject?) -> Bool? {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }
}

public final class AXTracker: @unchecked Sendable {
    public weak var delegate: AXTrackerDelegate?
    private var observers: [pid_t: AXObserver] = [:]
    private var axWindows: [WindowID: AXWindow] = [:]
    private var managed: [WindowID: ManagedWindow] = [:]
    private var runLoopSources: [pid_t: CFRunLoopSource] = [:]
    private var titleObservedTokens: Set<String> = []
    private var scanWorkItem: DispatchWorkItem?
    /// While > 0, ignore AX move/resize/miniaturize (self-caused layout noise).
    private var mutationDepth = 0
    private var suppressUntil = Date.distantPast
    /// Last scan diagnostics for status / debugging.
    public private(set) var lastScanTrusted = false
    public private(set) var lastScanAppCount = 0
    public private(set) var lastScanRawWindowCount = 0
    public private(set) var lastScanAcceptedCount = 0

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

    public func apply(frame: Rect, to id: WindowID) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            if ax.isMinimized { ax.isMinimized = false }
            if !framesApproximatelyEqual(ax.frame, frame) {
                ax.frame = frame
            }
        }
    }

    /// Move/resize without touching minimize — used for same-workspace fluid layout.
    public func applyFrameOnly(frame: Rect, to id: WindowID) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            if framesApproximatelyEqual(ax.frame, frame) { return }
            ax.frame = frame
            // Electron often ignores the first AX write — one retry recovers size/position.
            if !framesApproximatelyEqual(ax.frame, frame, epsilon: 6) {
                ax.frame = frame
            }
        }
    }

    /// Always write geometry (stack pairs must shrink the top tile before the bottom grows).
    public func forceFrame(_ frame: Rect, id: WindowID) {
        forceStackTileFrame(frame, id: id, positionFirst: false)
    }

    /// Stack layout: top tile uses size→pos→size; lower tiles use pos→size so growth moves up.
    public func forceStackTileFrame(_ frame: Rect, id: WindowID, positionFirst: Bool) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            if ax.isMinimized { ax.isMinimized = false }
            var point = CGPoint(x: frame.x, y: frame.y)
            var size = CGSize(width: frame.width, height: frame.height)
            if positionFirst {
                if let pos = AXValueCreate(.cgPoint, &point) {
                    AXUIElementSetAttributeValue(ax.element, kAXPositionAttribute as CFString, pos)
                }
                if let sz = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(ax.element, kAXSizeAttribute as CFString, sz)
                }
                if let sz = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(ax.element, kAXSizeAttribute as CFString, sz)
                }
            } else {
                ax.frame = frame
                if !framesApproximatelyEqual(ax.frame, frame, epsilon: 6) {
                    ax.frame = frame
                }
            }
        }
    }

    public func applyParked(frame: Rect, to id: WindowID) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            if !framesApproximatelyEqual(ax.frame, frame) {
                ax.frame = frame
            }
        }
    }

    public func isMinimized(_ id: WindowID) -> Bool {
        axWindows[id]?.isMinimized ?? false
    }

    /// True when the live AX frame already matches the target (on- or off-screen).
    /// Off-screen match must count as settled — column scroll parks tiles just past the
    /// usable edge without minimize; requiring on-monitor would re-apply every tick.
    public func isSettled(id: WindowID, frame: Rect, monitors: [Rect]) -> Bool {
        guard let ax = axWindows[id], !ax.isMinimized else { return false }
        return framesApproximatelyEqual(ax.frame, frame, epsilon: 4)
    }

    public func parkAndHide(frame: Rect, id: WindowID, monitors: [Rect] = []) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            let park = monitors.isEmpty
                ? (x: frame.x, y: frame.y)
                : OffscreenParking.parkOrigin(monitors: monitors, preferred: nil)
            // Keep real size — collapsing to 1×1 is rejected by Safari/Electron and macOS
            // clamps a visible strip of the full window onto the display edge.
            let parked = OffscreenParking.parkedFrame(origin: park, sizeFrom: frame, live: ax.frame)
            ax.frame = parked
            ax.isMinimized = true
            if !framesApproximatelyEqual(ax.frame, parked, epsilon: 8) {
                ax.frame = parked
            }
        }
    }

    /// Park without minimize — use when the same app still has visible windows (minimize is per-app on Electron).
    public func parkOffscreen(frame: Rect, id: WindowID, monitors: [Rect] = []) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            let origin = monitors.isEmpty
                ? (x: frame.x, y: frame.y)
                : OffscreenParking.parkOrigin(monitors: monitors, preferred: nil)
            let parked = OffscreenParking.parkedFrame(origin: origin, sizeFrom: frame, live: ax.frame)
            ax.frame = parked
            if !framesApproximatelyEqual(ax.frame, parked, epsilon: 8) {
                ax.frame = parked
            }
        }
    }

    /// Last applied off-screen park frame for an id (best-effort readback).
    public func currentParkedFrame(of id: WindowID, sizeFrom: Rect, monitors: [Rect]) -> Rect {
        let origin = OffscreenParking.parkOrigin(monitors: monitors, preferred: nil)
        let live = axWindows[id]?.frame ?? sizeFrom
        return OffscreenParking.parkedFrame(origin: origin, sizeFrom: sizeFrom, live: live)
    }

    /// Re-hide without touching geometry (sibling deminiaturize after focusing another app window).
    public func ensureMinimized(_ id: WindowID) {
        withMutation {
            guard let ax = axWindows[id], !ax.isMinimized else { return }
            ax.isMinimized = true
        }
    }

    /// Repark when a hidden/off-screen window still bleeds onto a display (edge strip or clamp).
    /// Must not touch normal on-screen tiles — intersectsAnyMonitor alone is true for every visible window.
    public func reparkIfLeaking(id: WindowID, monitors: [Rect], allowMinimize: Bool = true) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            let frame = ax.frame
            let edgeStrip = OffscreenParking.isEdgeStrip(frame, monitors: monitors)
            let parkedBleed = OffscreenParking.intersectsAnyMonitor(frame, monitors: monitors)
                && !OffscreenParking.isUsableOnscreenFrame(frame, monitors: monitors)
            guard edgeStrip || parkedBleed else { return }
            let park = OffscreenParking.parkOrigin(monitors: monitors, preferred: nil)
            let parked = OffscreenParking.parkedFrame(origin: park, sizeFrom: frame, live: frame)
            ax.frame = parked
            if allowMinimize {
                ax.isMinimized = true
                if !framesApproximatelyEqual(ax.frame, parked, epsilon: 8) {
                    ax.frame = parked
                }
            }
        }
    }

    public func reveal(frame: Rect, id: WindowID) {
        withMutation {
            guard let ax = axWindows[id] else { return }
            let needsFrame = !framesApproximatelyEqual(ax.frame, frame, epsilon: 4)
            let needsShow = ax.isMinimized
            // Already correct on-screen — do not touch (avoids close/reopen flash).
            guard needsFrame || needsShow else { return }

            // Place geometry first so deminiaturize never flashes at dock / park size.
            if needsFrame {
                ax.frame = frame
            }
            if needsShow {
                ax.isMinimized = false
            }
            // Always re-apply after deminiaturize: Electron/WhatsApp Chromium often keeps a
            // stale webview layout (composer clipped) unless size is written while visible.
            ax.frame = frame
            if !framesApproximatelyEqual(ax.frame, frame, epsilon: 4) {
                ax.frame = frame
            }
        }
    }

    /// Live AX frame if the window is still tracked.
    public func currentFrame(of id: WindowID) -> Rect? {
        guard let ax = axWindows[id] else { return nil }
        let f = ax.frame
        guard f.width > 1, f.height > 1 else { return nil }
        return f
    }

    /// Uncensored AX frame (includes edge-clamp strips used for leak detection).
    public func rawFrame(of id: WindowID) -> Rect? {
        guard let ax = axWindows[id] else { return nil }
        let f = ax.frame
        guard f.width > 0, f.height > 0 else { return nil }
        return f
    }

    /// Fresh title from AX / CG (not the last scan snapshot).
    public func currentTitle(of id: WindowID) -> String? {
        guard let ax = axWindows[id] else { return nil }
        let t = ax.resolvedTitle()
        return t.isEmpty ? nil : t
    }

    public func setMinimized(_ minimized: Bool, id: WindowID) {
        withMutation {
            axWindows[id]?.isMinimized = minimized
        }
    }

    public func focus(_ id: WindowID) {
        withMutation {
            axWindows[id]?.focus()
        }
    }

    @discardableResult
    public func closeWindow(_ id: WindowID) -> Bool {
        withMutation {
            axWindows[id]?.close() ?? false
        }
    }

    private func framesApproximatelyEqual(_ a: Rect, _ b: Rect, epsilon: Double = 2.0) -> Bool {
        abs(a.x - b.x) < epsilon
            && abs(a.y - b.y) < epsilon
            && abs(a.width - b.width) < epsilon
            && abs(a.height - b.height) < epsilon
    }

    public func restoreAllOnscreen(monitors: [Rect]) {
        guard let first = monitors.first else { return }
        for (_, ax) in axWindows {
            var f = ax.frame
            let onAny = monitors.contains { mon in
                f.midX >= mon.x && f.midX <= mon.maxX && f.midY >= mon.y && f.midY <= mon.maxY
            }
            if !onAny {
                f.x = first.x + 40
                f.y = first.y + 40
                f.width = min(f.width, first.width - 80)
                f.height = min(f.height, first.height - 80)
                ax.frame = f
            }
            if ax.isMinimized { ax.isMinimized = false }
        }
    }

    public var currentWindows: [ManagedWindow] { Array(managed.values) }
    public var currentAX: [WindowID: AXWindow] { axWindows }

    /// Focused window of the frontmost app, if we track it.
    public func frontmostFocusedWindowID() -> WindowID? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let el = focused else { return nil }
        return windowID(for: el as! AXUIElement)
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else { return }
        observe(pid: app.processIdentifier)
        scheduleScanAll(delay: 0.35)
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        if let source = runLoopSources.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        observers.removeValue(forKey: pid)
        let gone = axWindows.keys.filter { $0.pid == pid }
        for id in gone {
            axWindows.removeValue(forKey: id)
            managed.removeValue(forKey: id)
            titleObservedTokens.remove(id.token)
        }
        publish()
    }

    private func observe(pid: pid_t) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<AXTracker>.fromOpaque(refcon).takeUnretainedValue()
            tracker.handle(notification: notification as String, element: element)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        let app = AXUIElementCreateApplication(pid)
        let notes = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXMovedNotification,
            kAXResizedNotification,
            kAXTitleChangedNotification
        ]
        for note in notes {
            AXObserverAddNotification(observer, app, note as CFString, ref)
        }
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        observers[pid] = observer
        runLoopSources[pid] = source
    }

    private func observeTitle(on window: AXUIElement, pid: pid_t, token: String) {
        guard !titleObservedTokens.contains(token), let observer = observers[pid] else { return }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        let status = AXObserverAddNotification(
            observer,
            window,
            kAXTitleChangedNotification as CFString,
            ref
        )
        if status == .success || status == .notificationAlreadyRegistered {
            titleObservedTokens.insert(token)
        }
    }

    private func handle(notification: String, element: AXUIElement) {
        // Self-caused layout noise — ignore until settle (except destroy: red-X must not wait).
        if isMutating {
            if notification == kAXFocusedWindowChangedNotification as String,
               let id = windowID(for: element) {
                delegate?.axTrackerFocusedWindowDidChange(id)
            }
            if notification == kAXUIElementDestroyedNotification as String,
               let id = windowID(for: element) {
                delegate?.axTrackerWindowDidClose(id)
                scheduleScanAll(delay: 0.12)
            }
            return
        }

        if notification == kAXFocusedWindowChangedNotification as String {
            if let id = windowID(for: element) {
                refreshTitle(for: id)
                delegate?.axTrackerFocusedWindowDidChange(id)
            }
            // Focus alone should not full-rescan.
            return
        }

        if notification == kAXTitleChangedNotification as String {
            if let id = windowID(for: element) {
                refreshTitle(for: id)
            }
            return
        }

        // User/app moved or resized a window — let the WM re-assert tiled layout if needed.
        if notification == kAXMovedNotification as String
            || notification == kAXResizedNotification as String {
            if !isMutating, let id = windowID(for: element) {
                delegate?.axTrackerWindowGeometryChanged(id)
            }
            return
        }

        if notification == kAXUIElementDestroyedNotification as String {
            if let id = windowID(for: element) {
                // Drop local cache immediately so the next scan does not resurrect a ghost.
                axWindows.removeValue(forKey: id)
                managed.removeValue(forKey: id)
                delegate?.axTrackerWindowDidClose(id)
            }
            scheduleScanAll(delay: 0.12)
            return
        }

        // Create/deminiaturize — full rescan.
        let structural = notification == kAXWindowCreatedNotification as String
            || notification == kAXWindowDeminiaturizedNotification as String
        guard structural else { return }

        scheduleScanAll(delay: 0.28)
    }

    private func scheduleScanAll(delay: TimeInterval) {
        scanWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isMutating else { return }
            self.scanAll()
        }
        scanWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func windowID(for element: AXUIElement) -> WindowID? {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if let n = readWindowNumber(element) {
            return WindowID(pid: pid, windowNumber: n)
        }
        return axWindows.first(where: { CFEqual($0.value.element, element) })?.key
    }

    private func readWindowNumber(_ element: AXUIElement) -> Int? {
        var numObj: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXWindowNumberAttribute as CFString, &numObj) == .success,
           let n = AXBridge.int(numObj) {
            return n
        }
        return nil
    }

    /// On-screen CG window numbers by PID (fallback when AXWindowNumber is missing).
    private func cgWindowNumbersByPID() -> [pid_t: [Int]] {
        var result: [pid_t: [Int]] = [:]
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return result }

        for info in infos {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t
                    ?? (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let num = info[kCGWindowNumber as String] as? Int
                    ?? (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let layer = info[kCGWindowLayer as String] as? Int
                    ?? (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0
            else { continue }
            result[pid, default: []].append(num)
        }
        return result
    }

    public func scanAll() {
        let previousManaged = managed
        lastScanTrusted = Self.isTrusted
        if !lastScanTrusted {
            NSLog("ALWM AX: Accessibility NOT trusted — window management disabled until granted")
        }

        let cgByPid = cgWindowNumbersByPID()
        var nextAX: [WindowID: AXWindow] = [:]
        var nextManaged: [WindowID: ManagedWindow] = [:]
        var appsSeen = 0
        var rawWindows = 0
        var skippedNoNumber = 0
        var skippedFilter = 0

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !$0.isTerminated
        }
        appsSeen = apps.count

        for app in apps {
            let pid = app.processIdentifier
            if app.bundleIdentifier == "dev.alwm.ALWM" { continue }
            observe(pid: pid)

            let appEl = AXUIElementCreateApplication(pid)
            var windowsValue: AnyObject?
            let copyStatus = AXUIElementCopyAttributeValue(
                appEl,
                kAXWindowsAttribute as CFString,
                &windowsValue
            )
            guard copyStatus == .success else { continue }

            guard let windows = windowsValue as? [AXUIElement] else { continue }

            var cgPool = cgByPid[pid] ?? []
            for winEl in windows {
                rawWindows += 1
                let axProbe = AXWindow(
                    id: WindowID(pid: pid, windowNumber: -1),
                    element: winEl,
                    pid: pid
                )
                guard axProbe.isStandardWindow else {
                    skippedFilter += 1
                    continue
                }

                let num: Int
                if let n = readWindowNumber(winEl) {
                    num = n
                } else if let existing = axWindows.first(where: { CFEqual($0.value.element, winEl) })?.key {
                    // Keep prior id for this AX element (stable across rescans).
                    num = existing.windowNumber
                } else if !cgPool.isEmpty {
                    num = cgPool.removeFirst()
                } else {
                    // Stable for the life of the AXUIElement — never use list index.
                    num = Int(CFHash(winEl) & 0x7FFF_FFFF)
                    skippedNoNumber += 1
                }

                let id = WindowID(pid: pid, windowNumber: num)
                let ax = AXWindow(id: id, element: winEl, pid: pid)
                nextAX[id] = ax
                nextManaged[id] = ManagedWindow(
                    id: id,
                    title: ax.resolvedTitle(),
                    bundleID: app.bundleIdentifier,
                    appName: app.localizedName ?? "App",
                    frame: ax.frame,
                    isFloating: ax.prefersFloating
                )
                observeTitle(on: winEl, pid: pid, token: id.token)
            }
        }

        lastScanAppCount = appsSeen
        lastScanRawWindowCount = rawWindows
        lastScanAcceptedCount = nextManaged.count

        if nextManaged.count == 0 {
            NSLog(
                "ALWM AX: scan empty (trusted=%@ apps=%d rawWindows=%d skippedFilter=%d missingNumber≈%d)",
                lastScanTrusted ? "yes" : "no",
                appsSeen,
                rawWindows,
                skippedFilter,
                skippedNoNumber
            )
        } else if nextManaged.count != managed.count {
            NSLog("ALWM AX: tracking %d windows", nextManaged.count)
        }

        axWindows = nextAX
        managed = nextManaged
        let liveTokens = Set(nextAX.keys.map(\.token))
        titleObservedTokens = titleObservedTokens.intersection(liveTokens)
        publishIfNeeded(previousManaged: previousManaged)
    }

    /// Update a single window title without a full AX rescan (Electron apps change titles often).
    private func refreshTitle(for id: WindowID) {
        guard let ax = axWindows[id], var win = managed[id] else { return }
        let next = ax.resolvedTitle()
        guard next != win.title else { return }
        win.title = next
        managed[id] = win
        delegate?.axTrackerWindowTitleDidChange(id, window: win)
    }

    private func publish() {
        delegate?.axTrackerDidUpdateWindows(Array(managed.values), axWindows: axWindows)
    }

    /// Avoid full ingest when a rescan only refreshed titles on the same window set.
    private func publishIfNeeded(previousManaged: [WindowID: ManagedWindow]) {
        let prevKeys = Set(previousManaged.keys)
        let nextKeys = Set(managed.keys)
        guard prevKeys == nextKeys else {
            publish()
            return
        }
        var titleOnly = false
        for (id, win) in managed {
            guard let prev = previousManaged[id] else {
                publish()
                return
            }
            if prev.frame != win.frame
                || prev.bundleID != win.bundleID
                || prev.appName != win.appName
                || prev.isFloating != win.isFloating
                || prev.isIgnored != win.isIgnored
                || prev.isScratchpad != win.isScratchpad {
                publish()
                return
            }
            if prev.title != win.title {
                titleOnly = true
            }
        }
        guard titleOnly else { return }
        for (id, win) in managed where previousManaged[id]?.title != win.title {
            delegate?.axTrackerWindowTitleDidChange(id, window: win)
        }
    }
}

private let kAXWindowNumberAttribute = "AXWindowNumber"
