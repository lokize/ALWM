import AppKit
import CoreGraphics
import Foundation

/// Consumes clicks outside auto-dismissing overlays before WindowServer can
/// activate the covered application. Ordinary NSEvent monitors cannot do this
/// for clicks delivered to another process.
final class OverlayClickCapture: @unchecked Sendable {
    private struct State {
        var visibleFrames: [Rect] = []
        var dismissOnClickOutside = false
        var swallowedButtons: Set<Int64> = []
        var onOutsideClick: (@MainActor @Sendable (CGPoint) -> Void)?
    }

    private final class LockedState: @unchecked Sendable {
        private let lock = NSLock()
        private var value = State()

        func read<T>(_ body: (State) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(value)
        }

        func update<T>(_ body: (inout State) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    private let state = LockedState()
    @MainActor private var eventTap: CFMachPort?
    @MainActor private var runLoopSource: CFRunLoopSource?

    @MainActor
    init() {}

    @MainActor
    func update(
        visibleFrames: [Rect],
        dismissOnClickOutside: Bool,
        onOutsideClick: @escaping @MainActor @Sendable (CGPoint) -> Void
    ) {
        state.update { value in
            value.visibleFrames = visibleFrames
            value.dismissOnClickOutside = dismissOnClickOutside && !visibleFrames.isEmpty
            value.onOutsideClick = onOutsideClick
        }

        if !visibleFrames.isEmpty {
            installTapIfNeeded()
        } else {
            removeTap()
        }
    }

    @MainActor
    func stop() {
        state.update { value in
            value.dismissOnClickOutside = false
            value.visibleFrames.removeAll()
            value.onOutsideClick = nil
            value.swallowedButtons.removeAll()
        }
        removeTap()
    }

    @MainActor
    private func installTapIfNeeded() {
        guard eventTap == nil else {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return
        }

        let eventTypes: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let capture = Unmanaged<OverlayClickCapture>.fromOpaque(userInfo).takeUnretainedValue()
                return capture.handle(type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            NSLog("ALWM: outside-click capture could not create a mouse event tap")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    @MainActor
    private func removeTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in self?.installTapIfNeeded() }
            return Unmanaged.passUnretained(event)
        }

        guard let button = Self.buttonNumber(for: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }

        let location = button.kind == .down ? event.location : nil
        let shouldCheckAppWindow: Bool
        if let location {
            shouldCheckAppWindow = state.read { value in
                !value.visibleFrames.isEmpty && !value.visibleFrames.contains {
                    $0.contains(pointX: location.x, pointY: location.y)
                }
            }
        } else {
            shouldCheckAppWindow = false
        }
        let frontmostWindowOwnerPID: pid_t?
        if shouldCheckAppWindow, let location {
            frontmostWindowOwnerPID = Self.frontmostWindowOwnerPID(at: location)
        } else {
            frontmostWindowOwnerPID = nil
        }

        let result = state.update { value -> (consume: Bool, callback: (@MainActor @Sendable (CGPoint) -> Void)?, point: CGPoint?) in
            if button.kind == .down {
                guard let location else { return (false, nil, nil) }
                let insideOverlay = value.visibleFrames.contains {
                    $0.contains(pointX: location.x, pointY: location.y)
                }
                let outside = OverlayClickCapturePolicy.shouldConsumeOutsideClick(
                    pointX: location.x,
                    pointY: location.y,
                    visibleFrames: value.visibleFrames,
                    frontmostWindowOwnerPID: insideOverlay ? nil : frontmostWindowOwnerPID
                )
                guard outside else { return (false, nil, nil) }
                value.swallowedButtons.insert(button.number)
                return (true, value.dismissOnClickOutside ? value.onOutsideClick : nil, location)
            }

            guard value.swallowedButtons.contains(button.number) else { return (false, nil, nil) }
            if button.kind == .up { value.swallowedButtons.remove(button.number) }
            return (true, nil, nil)
        }

        if let callback = result.callback, let point = result.point {
            Task { @MainActor in callback(point) }
        }
        return result.consume ? nil : Unmanaged.passUnretained(event)
    }

    /// The visible overlay's own frame is cached. Query WindowServer only for
    /// outside points, where an auxiliary menu/popover may own the hit target.
    private static func frontmostWindowOwnerPID(at point: CGPoint) -> pid_t? {
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return OverlayClickCapturePolicy.windowOwnerPID(
            atX: point.x,
            y: point.y,
            windowInfos: infos
        )
    }

    private struct MouseButton {
        enum Kind { case down, drag, up }
        var number: Int64
        var kind: Kind
    }

    private static func buttonNumber(for type: CGEventType, event: CGEvent) -> MouseButton? {
        switch type {
        case .leftMouseDown: return MouseButton(number: 0, kind: .down)
        case .leftMouseDragged: return MouseButton(number: 0, kind: .drag)
        case .leftMouseUp: return MouseButton(number: 0, kind: .up)
        case .rightMouseDown: return MouseButton(number: 1, kind: .down)
        case .rightMouseDragged: return MouseButton(number: 1, kind: .drag)
        case .rightMouseUp: return MouseButton(number: 1, kind: .up)
        case .otherMouseDown:
            return MouseButton(number: event.getIntegerValueField(.mouseEventButtonNumber), kind: .down)
        case .otherMouseDragged:
            return MouseButton(number: event.getIntegerValueField(.mouseEventButtonNumber), kind: .drag)
        case .otherMouseUp:
            return MouseButton(number: event.getIntegerValueField(.mouseEventButtonNumber), kind: .up)
        default:
            return nil
        }
    }
}
