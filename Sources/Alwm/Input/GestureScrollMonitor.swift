import AppKit
import CoreGraphics
import Darwin
import Foundation

/// Trackpad scroll / swipe via CGEventTap + NSEvent monitors + raw MultitouchSupport.
///
/// On modern macOS, 3/4-finger swipes are often **not** delivered as scroll/swipe NSEvents
/// (especially when system Trackpad “Swipe between…” is off). Finger count alone is useless
/// without deltas — so we compute swipe direction from MultitouchSupport contact frames.
public final class GestureScrollMonitor: @unchecked Sendable {
    public struct Signal: Sendable {
        public var fingers: Int
        public var dx: Double
        public var dy: Double
        public var ended: Bool
    }

    private var nsGlobalMonitor: Any?
    private var nsLocalMonitor: Any?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastFingers: Int = 2
    private var lastEmitAt: CFAbsoluteTime = 0
    private let multitouch = MultitouchFingerTracker()

    public var onSignal: ((Signal) -> Void)?

    public init() {}

    public func start() {
        stop()
        multitouch.start(
            onFingerCount: { [weak self] count in
                guard let self, (2...5).contains(count) else { return }
                self.lastFingers = count
            },
            onSwipe: { [weak self] fingers, dx, dy, ended in
                self?.emit(fingers: fingers, dx: dx, dy: dy, ended: ended, force: ended)
            }
        )
        let installed = installEventTap()
        installNSMonitors()
        NSLog(
            "ALWM gestures: tap=%@ nsMonitor=%@ multitouch=%@",
            installed ? "yes" : "no",
            nsGlobalMonitor != nil ? "yes" : "no",
            multitouch.isRunning ? "yes" : "no"
        )
        if !Permissions.inputMonitoringGranted() {
            Permissions.requestInputMonitoring()
            NSLog("ALWM gestures: Input Monitoring not granted — 3/4-finger swipes need it")
        }
    }

    public func stop() {
        if let nsGlobalMonitor {
            NSEvent.removeMonitor(nsGlobalMonitor)
            self.nsGlobalMonitor = nil
        }
        if let nsLocalMonitor {
            NSEvent.removeMonitor(nsLocalMonitor)
            self.nsLocalMonitor = nil
        }
        tearDownEventTap()
        multitouch.stop()
        lastFingers = 2
    }

    private func installNSMonitors() {
        let mask: NSEvent.EventTypeMask = [
            .scrollWheel,
            .swipe,
            .beginGesture,
            .endGesture,
            .gesture
        ]
        nsGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleNSEvent(event)
        }
        nsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
    }

    private func installEventTap() -> Bool {
        guard Permissions.inputMonitoringGranted() else { return false }
        var mask: CGEventMask = 1 << CGEventType.scrollWheel.rawValue
        if let gestureType = CGEventType(rawValue: 29) {
            mask |= 1 << gestureType.rawValue
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let tap =
            CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let monitor = Unmanaged<GestureScrollMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                    monitor.handleCGEvent(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: userInfo
            )
            ?? CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let monitor = Unmanaged<GestureScrollMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                    monitor.handleCGEvent(type: type, event: event)
                    return Unmanaged.passUnretained(event)
                },
                userInfo: userInfo
            )
        guard let tap else {
            NSLog("ALWM gestures: CGEventTap failed")
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func tearDownEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        // Prefer raw multitouch while 3/4 fingers are on the pad.
        if multitouch.fingerCount >= 3 { return }
        if let ns = NSEvent(cgEvent: event) {
            handleNSEvent(ns)
            return
        }
        guard type == .scrollWheel else { return }
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        guard abs(dx) > 0.05 || abs(dy) > 0.05 else { return }
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        let ended = phase == 8 || momentum == 8
        let fingers = resolvedFingers(fallback: lastFingers)
        emit(fingers: fingers, dx: -dx, dy: -dy, ended: ended)
    }

    private func handleNSEvent(_ event: NSEvent) {
        // Raw multitouch owns active 3/4-finger gestures (no scroll/swipe NSEvents).
        if multitouch.isRunning, multitouch.fingerCount >= 3 {
            return
        }

        switch event.type {
        case .swipe:
            let resolved = resolvedFingers(fallback: max(3, lastFingers >= 4 ? 4 : 3))
            lastFingers = resolved
            let dx = Double(event.deltaX) * 160
            let dy = Double(event.deltaY) * 160
            if abs(dx) <= 0.5, abs(dy) <= 0.5 {
                emit(fingers: resolved, dx: 0, dy: 0, ended: true)
            } else {
                emit(fingers: resolved, dx: -dx, dy: -dy, ended: true)
            }

        case .beginGesture:
            lastFingers = resolvedFingers(fallback: lastFingers)

        case .endGesture:
            emit(fingers: lastFingers, dx: 0, dy: 0, ended: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                if self.multitouch.fingerCount < 2 {
                    self.lastFingers = 2
                }
            }

        case .gesture:
            lastFingers = resolvedFingers(fallback: lastFingers)

        case .scrollWheel:
            let dx = event.hasPreciseScrollingDeltas
                ? Double(event.scrollingDeltaX)
                : Double(event.deltaX) * 10
            let dy = event.hasPreciseScrollingDeltas
                ? Double(event.scrollingDeltaY)
                : Double(event.deltaY) * 10
            let ended = event.phase == .ended || event.momentumPhase == .ended
                || event.phase == .cancelled
            guard abs(dx) > 0.05 || abs(dy) > 0.05 else {
                if ended { emit(fingers: lastFingers, dx: 0, dy: 0, ended: true) }
                return
            }
            let fingers = resolvedFingers(event: event, fallback: lastFingers)
            lastFingers = fingers
            emit(fingers: fingers, dx: -dx, dy: -dy, ended: ended)

        default:
            break
        }
    }

    private func resolvedFingers(event: NSEvent? = nil, fallback: Int) -> Int {
        if multitouch.fingerCount >= 2 { return multitouch.fingerCount }
        if let event, let n = Self.touchCount(from: event) { return n }
        return fallback
    }

    private func emit(fingers: Int, dx: Double, dy: Double, ended: Bool, force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        // Multitouch 3/4-finger: almost no coalesce — latency kills the Niri feel.
        let minInterval = fingers >= 3 ? 0.002 : 0.008
        if !force, !ended, now - lastEmitAt < minInterval, abs(dx) < 40, abs(dy) < 40 {
            return
        }
        lastEmitAt = now
        DispatchQueue.main.async { [weak self] in
            self?.onSignal?(Signal(fingers: fingers, dx: dx, dy: dy, ended: ended))
        }
    }

    private static func touchCount(from event: NSEvent) -> Int? {
        let touches = event.touches(matching: [.touching, .began, .moved, .stationary], in: nil)
        let n = touches.count
        guard (2...5).contains(n) else { return nil }
        return n
    }
}

// MARK: - MultitouchSupport

/// Live finger count + swipe deltas from the trackpad via private MultitouchSupport.framework.
final class MultitouchFingerTracker: @unchecked Sendable {
    private(set) var isRunning = false
    private(set) var fingerCount = 0

    private var devices: [UnsafeMutableRawPointer] = []
    /// Must outlive `devices` — releasing this CFArray while devices are started caused
    /// `CFRelease(NULL)` / SIGTRAP on the Multitouch HID thread (ALWM quits when using Quake
    /// or when gestures restart).
    private var deviceList: CFArray?
    private var onFingerCount: ((Int) -> Void)?
    private var onSwipe: ((Int, Double, Double, Bool) -> Void)?
    private let lock = NSLock()

    /// Keep MultitouchSupport loaded for process lifetime — dlclose races MTDeviceStop.
    private nonisolated(unsafe) static let sharedLib: UnsafeMutableRawPointer? = {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        return dlopen(path, RTLD_NOW)
    }()

    private typealias MTDeviceCreateListFn = @convention(c) () -> Unmanaged<CFMutableArray>?
    private typealias MTContactCallback = @convention(c) (
        UnsafeMutableRawPointer?,
        UnsafeMutableRawPointer?,
        Int32,
        Double,
        Int32
    ) -> Int32
    private typealias MTRegisterFn = @convention(c) (UnsafeMutableRawPointer?, MTContactCallback?) -> Void
    private typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void
    private typealias MTDeviceStopFn = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private var registerCB: MTRegisterFn?
    private var unregisterCB: MTRegisterFn?
    private var startDev: MTDeviceStartFn?
    private var stopDev: MTDeviceStopFn?
    private var callback: MTContactCallback?

    /// Gesture in progress (fingers down).
    private var activeFingers: Int = 0
    private var startCentroid: (x: Double, y: Double)?
    private var lastCentroid: (x: Double, y: Double)?
    private var totalDx: Double = 0
    private var totalDy: Double = 0
    private var gestureEmitted = false
    /// Consecutive frames with &lt;3 fingers before we emit ended (avoids flicker snap).
    private var lowFingerFrames: Int = 0
    /// Scale normalized trackpad coords (0…1) → scroll units (tuned for Magic Trackpad ↔ Niri feel).
    private let scale: Double = 980

    // Multitouch callbacks arrive on a private HID thread — unsafe bridge to instance.
    private static nonisolated(unsafe) weak var active: MultitouchFingerTracker?

    func start(
        onFingerCount: @escaping (Int) -> Void,
        onSwipe: @escaping (Int, Double, Double, Bool) -> Void
    ) {
        stop()
        lock.lock()
        defer { lock.unlock() }

        self.onFingerCount = onFingerCount
        self.onSwipe = onSwipe

        guard let handle = Self.sharedLib else {
            NSLog("ALWM gestures: MultitouchSupport dlopen failed")
            return
        }

        let createList = unsafeBitCast(dlsym(handle, "MTDeviceCreateList"), to: MTDeviceCreateListFn?.self)
        registerCB = unsafeBitCast(dlsym(handle, "MTRegisterContactFrameCallback"), to: MTRegisterFn?.self)
        // Optional — older SDKs may not export unregister; stop still works if present.
        unregisterCB = unsafeBitCast(dlsym(handle, "MTUnregisterContactFrameCallback"), to: MTRegisterFn?.self)
        startDev = unsafeBitCast(dlsym(handle, "MTDeviceStart"), to: MTDeviceStartFn?.self)
        stopDev = unsafeBitCast(dlsym(handle, "MTDeviceStop"), to: MTDeviceStopFn?.self)

        guard let createList, let registerCB, let startDev else {
            NSLog("ALWM gestures: MultitouchSupport symbols missing")
            return
        }

        let callback: MTContactCallback = { _, touches, nFingers, _, _ in
            MultitouchFingerTracker.active?.handleFrame(touches: touches, count: Int(nFingers))
            return 0
        }
        self.callback = callback
        MultitouchFingerTracker.active = self

        guard let list = createList()?.takeRetainedValue() else {
            MultitouchFingerTracker.active = nil
            NSLog("ALWM gestures: MTDeviceCreateList returned nil")
            return
        }
        // Retain the array for as long as devices stay started.
        deviceList = list
        let count = CFArrayGetCount(list)
        for i in 0..<count {
            guard let value = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: value)
            registerCB(device, callback)
            startDev(device, 0)
            devices.append(device)
        }
        isRunning = !devices.isEmpty
        NSLog("ALWM gestures: multitouch devices=%d", devices.count)
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }

        // Drop active first so HID callbacks become no-ops before MTDeviceStop.
        if MultitouchFingerTracker.active === self {
            MultitouchFingerTracker.active = nil
        }

        let devicesToStop = devices
        let unregister = unregisterCB
        let stop = stopDev
        let cb = callback
        devices.removeAll()
        callback = nil
        registerCB = nil
        unregisterCB = nil
        startDev = nil
        stopDev = nil

        for device in devicesToStop {
            if let unregister, let cb {
                unregister(device, cb)
            }
            // Guard nil device — MTDeviceStop → CFRelease(NULL) is a hard crash on macOS 26/27.
            if let stop, device != UnsafeMutableRawPointer(bitPattern: 0) {
                stop(device)
            }
        }

        // Release CFArray only after stop/unregister (devices live inside it).
        deviceList = nil
        fingerCount = 0
        isRunning = false
        onFingerCount = nil
        onSwipe = nil
        resetGesture()
    }

    private func resetGesture() {
        activeFingers = 0
        startCentroid = nil
        lastCentroid = nil
        totalDx = 0
        totalDy = 0
        gestureEmitted = false
        lowFingerFrames = 0
    }

    private func handleFrame(touches: UnsafeMutableRawPointer?, count: Int) {
        let clamped = max(0, min(count, 5))
        fingerCount = clamped
        if clamped >= 2 {
            onFingerCount?(clamped)
        }

        // Only drive gestures from 3+ fingers (2-finger stays with native scroll when possible).
        if clamped >= 3, let touches {
            lowFingerFrames = 0
            let centroid = averageNormalized(touches: touches, count: clamped)
            if activeFingers == 0 {
                activeFingers = clamped
                startCentroid = centroid
                lastCentroid = centroid
                totalDx = 0
                totalDy = 0
                gestureEmitted = false
            } else {
                // Finger count changed mid-gesture — retarget but keep going.
                if clamped != activeFingers {
                    activeFingers = clamped
                }
                if let last = lastCentroid {
                    let stepDx = (centroid.x - last.x) * scale
                    let stepDy = (centroid.y - last.y) * scale
                    totalDx += stepDx
                    totalDy += stepDy
                    // Continuous updates for scroll.columns (3/4-finger horizontal).
                    if abs(stepDx) > 0.12 || abs(stepDy) > 0.12 {
                        onSwipe?(clamped, stepDx, stepDy, false)
                    }
                }
                lastCentroid = centroid
            }
            return
        }

        // Lift: require several consecutive low-finger frames so a one-frame flicker
        // does not emit ended (which used to snap columns back mid-pan).
        if activeFingers >= 3 {
            lowFingerFrames += 1
            if lowFingerFrames < 4 {
                return
            }
            let fingers = activeFingers
            NSLog(
                "ALWM multitouch swipe end: fingers=%d totalDx=%.1f totalDy=%.1f",
                fingers, totalDx, totalDy
            )
            onSwipe?(fingers, 0, 0, true)
            resetGesture()
            if clamped < 2 {
                fingerCount = 0
            }
        }
    }

    /// Average normalized (x,y) of active contacts. Layout matches common MTTouch reverse-engineering.
    private func averageNormalized(touches: UnsafeMutableRawPointer, count: Int) -> (x: Double, y: Double) {
        // MTTouch (calftrail / OpenMultitouchSupport style):
        // frame:i32, timestamp:f64, id:i32, state:i32, unk:i32, unk:i32, normalized:{f32,f32}, …
        struct MTPoint { var x: Float; var y: Float }
        struct MTTouch {
            var frame: Int32
            var timestamp: Double
            var identifier: Int32
            var state: Int32
            var unknown1: Int32
            var unknown2: Int32
            var normalized: MTPoint
            var size: Float
            var unknown3: Int32
            var angle: Float
            var majorAxis: Float
            var minorAxis: Float
            var absolute: MTPoint
            var unknown4: Int32
            var unknown5: Int32
            var unknown6: Float
        }

        let buffer = touches.assumingMemoryBound(to: MTTouch.self)
        var sx: Double = 0
        var sy: Double = 0
        var n = 0
        for i in 0..<count {
            let t = buffer[i]
            // States 1…7 typically cover make/touch/break; ignore empty slots.
            guard t.state > 0, t.state < 8 else { continue }
            sx += Double(t.normalized.x)
            sy += Double(t.normalized.y)
            n += 1
        }
        if n == 0 {
            return (0.5, 0.5)
        }
        return (sx / Double(n), sy / Double(n))
    }
}
