import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Global hotkeys via CGEventTap (HID) + Carbon + NSEvent monitor.
/// Option-only chords (esp. ⌥`) are unreliable on Carbon alone under recent macOS /
/// ABNT layouts, so we keep three independent paths with debounce.
public final class HotkeyManager: @unchecked Sendable {
    public var onAction: ((String) -> Void)?
    /// When true, swallow layout hotkeys but still allow overlay toggle actions.
    public var shouldDeferHotkeys: (() -> Bool)?
    /// Actions that remain active while `shouldDeferHotkeys` is true (overlay toggles).
    public var overlayToggleActions: Set<String> = ["quake.toggle", "notepad.toggle", "notepad.new"]

    private struct TapBinding {
        let keyCode: Int64
        let flags: CGEventFlags
        let action: String
        let isGrave: Bool
    }

    private var tapBindings: [TapBinding] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var nsMonitor: Any?
    private var nsLocalMonitor: Any?

    private var hotKeys: [UInt32: EventHotKeyRef] = [:]
    private var actionByID: [UInt32: String] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var lastActionAt: [String: CFAbsoluteTime] = [:]
    private var registeredBindings: [HotkeyBinding] = []
    /// When true the HID tap is disabled so overlay typing is not delayed or dropped.
    private var overlayKeyboardCaptureActive = false

    public init() {}

    public func register(bindings: [HotkeyBinding]) {
        registeredBindings = bindings
        unregisterAll()
        // Deduplicate actions so Option+grave does not register twice from codes 50+10
        // and still fire once; keep one TapBinding per (action, flags, keyCode).
        var seen = Set<String>()
        tapBindings = bindings.flatMap { binding -> [TapBinding] in
            let grave = Self.isGraveKey(binding.key)
            return Self.keyCodes(for: binding.key).compactMap { code -> TapBinding? in
                let key = "\(binding.action)|\(code)|\(binding.modifiers.sorted().joined(separator: "+"))"
                guard seen.insert(key).inserted else { return nil }
                return TapBinding(
                    keyCode: Int64(code),
                    flags: Self.cgModifiers(binding.modifiers),
                    action: binding.action,
                    isGrave: grave
                )
            }
        }

        // Brazilian Pro: Option + Esc-adjacent key is often reported as quote/' with code 50.
        // Ensure quake.toggle Option bindings also listen on that hardware key.
        for binding in bindings where binding.action == "quake.toggle" && Self.isGraveKey(binding.key) {
            let flags = Self.cgModifiers(binding.modifiers)
            for code: Int64 in [50, 10] {
                let key = "\(binding.action)|\(code)|\(binding.modifiers.sorted().joined(separator: "+"))"
                if seen.insert(key).inserted {
                    tapBindings.append(TapBinding(keyCode: code, flags: flags, action: binding.action, isGrave: true))
                }
            }
        }

        let monitoring = Permissions.inputMonitoringGranted()
        if monitoring {
            installEventTapIfNeeded()
            installNSMonitorIfNeeded()
        } else {
            Permissions.requestInputMonitoring()
        }

        // Carbon always — covers cases where the tap is denied/disabled mid-session.
        registerCarbon(bindings: bindings)
        NSLog(
            "ALWM hotkeys: tap=%@ nsMonitor=%@ carbon=%d bindings=%d graveCodes=50,10",
            eventTap != nil ? "yes" : "no",
            nsMonitor != nil ? "yes" : "no",
            hotKeys.count,
            tapBindings.count
        )
    }

    /// Suspend global hotkey capture while quake/notepad owns the keyboard.
    /// Tears down HID tap, NSEvent monitors, and all Carbon registrations.
    public func setOverlayKeyboardCapture(_ active: Bool) {
        guard overlayKeyboardCaptureActive != active else { return }
        overlayKeyboardCaptureActive = active
        if active {
            tearDownEventTap()
            if let nsMonitor {
                NSEvent.removeMonitor(nsMonitor)
                self.nsMonitor = nil
            }
            if let nsLocalMonitor {
                NSEvent.removeMonitor(nsLocalMonitor)
                self.nsLocalMonitor = nil
            }
            unregisterAllCarbonHotkeys()
        } else {
            if Permissions.inputMonitoringGranted() {
                installEventTapIfNeeded()
                installNSMonitorIfNeeded()
            }
            registerCarbon(bindings: registeredBindings)
        }
    }

    private func unregisterAllCarbonHotkeys() {
        for (_, ref) in hotKeys {
            UnregisterEventHotKey(ref)
        }
        hotKeys.removeAll()
        actionByID.removeAll()
        nextID = 1
    }

    public func unregisterAll() {
        overlayKeyboardCaptureActive = false
        for (_, ref) in hotKeys {
            UnregisterEventHotKey(ref)
        }
        hotKeys.removeAll()
        actionByID.removeAll()
        tearDownEventTap()
        if let nsMonitor {
            NSEvent.removeMonitor(nsMonitor)
            self.nsMonitor = nil
        }
        if let nsLocalMonitor {
            NSEvent.removeMonitor(nsLocalMonitor)
            self.nsLocalMonitor = nil
        }
        tapBindings.removeAll()
    }

    deinit {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    private func emit(_ action: String) {
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastActionAt[action], now - last < 0.15 {
            return
        }
        if shouldDeferHotkeys?() == true, !overlayToggleActions.contains(action) {
            return
        }
        lastActionAt[action] = now
        NSLog("ALWM hotkey: %@", action)
        DispatchQueue.main.async { [weak self] in
            self?.onAction?(action)
        }
    }

    // MARK: - CGEventTap

    private func installEventTapIfNeeded() {
        guard eventTap == nil else { return }
        let mask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        // HID tap sits above session taps (Ghostty quick-terminal, etc.).
        let tap =
            CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                    guard let userInfo else { return Unmanaged.passUnretained(event) }
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                    return manager.handleTap(type: type, event: event)
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
                    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                    return manager.handleTap(type: type, event: event)
                },
                userInfo: userInfo
            )
        guard let tap else {
            NSLog("ALWM: CGEventTap for hotkeys failed — grant Input Monitoring and relaunch")
            return
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: !overlayKeyboardCaptureActive)
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

    private func installNSMonitorIfNeeded() {
        guard nsMonitor == nil else { return }
        nsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleNSEvent(event)
        }
        if nsLocalMonitor == nil {
            nsLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }
                if self.handleNSEvent(event) {
                    return nil
                }
                return event
            }
        }
    }

    /// Returns true when the event was handled (and should be swallowed locally).
    @discardableResult
    private func handleNSEvent(_ event: NSEvent) -> Bool {
        if overlayKeyboardCaptureActive || shouldDeferHotkeys?() == true {
            return handleOverlayToggleNSEvent(event)
        }
        if Self.isEditingTextField() { return false }
        let deferOverlay = shouldDeferHotkeys?() == true
        let keyCode = Int64(event.keyCode)
        let flags = Self.cgFlags(from: event.modifierFlags)
        for binding in tapBindings {
            if Self.flagsMatch(binding.flags, event: flags, isGrave: binding.isGrave),
               Self.keyMatches(
                binding: binding,
                eventKeyCode: keyCode,
                characters: event.characters,
                ignoring: event.charactersIgnoringModifiers
               ) {
                if deferOverlay, !overlayToggleActions.contains(binding.action) {
                    return false
                }
                emit(binding.action)
                return true
            }
        }
        return false
    }

    /// While an overlay owns the keyboard, only swallow explicit overlay-toggle chords.
    @discardableResult
    private func handleOverlayToggleNSEvent(_ event: NSEvent) -> Bool {
        let keyCode = Int64(event.keyCode)
        let flags = Self.cgFlags(from: event.modifierFlags)
        for binding in tapBindings where overlayToggleActions.contains(binding.action) {
            guard Self.flagsMatch(binding.flags, event: flags, isGrave: binding.isGrave) else { continue }
            guard Self.keyMatches(
                binding: binding,
                eventKeyCode: keyCode,
                characters: event.characters,
                ignoring: event.charactersIgnoringModifiers
            ) else { continue }
            emit(binding.action)
            return true
        }
        return false
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        let f = flags.intersection(.deviceIndependentFlagsMask)
        if f.contains(.command) { out.insert(.maskCommand) }
        if f.contains(.shift) { out.insert(.maskShift) }
        if f.contains(.option) { out.insert(.maskAlternate) }
        if f.contains(.control) { out.insert(.maskControl) }
        return out
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap, !overlayKeyboardCaptureActive {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        if overlayKeyboardCaptureActive {
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // Fast path: every ALWM hotkey uses modifiers. Plain typing must leave the
        // HID stream immediately — slow work here disables the tap (keys drop).
        let flags = event.flags.intersection(Self.modifierMask)
        guard !flags.isEmpty else {
            return Unmanaged.passUnretained(event)
        }
        if shouldDeferHotkeys?() == true {
            return handleOverlayToggleTap(event: event, flags: flags)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        var needsChars = false
        var anyFlagMatch = false
        for binding in tapBindings {
            if Self.flagsMatch(binding.flags, event: flags, isGrave: binding.isGrave) {
                anyFlagMatch = true
                if binding.isGrave { needsChars = true }
                if binding.keyCode == keyCode, !binding.isGrave {
                    if shouldDeferHotkeys?() == true, !overlayToggleActions.contains(binding.action) {
                        return Unmanaged.passUnretained(event)
                    }
                    if Self.isEditingTextField() {
                        return Unmanaged.passUnretained(event)
                    }
                    emit(binding.action)
                    return Unmanaged.passUnretained(event)
                }
            }
        }
        guard anyFlagMatch else {
            return Unmanaged.passUnretained(event)
        }

        var chars: String?
        var ignoring: String?
        if needsChars, let ns = NSEvent(cgEvent: event) {
            chars = ns.characters
            ignoring = ns.charactersIgnoringModifiers
        }
        for binding in tapBindings where binding.isGrave {
            guard Self.flagsMatch(binding.flags, event: flags, isGrave: true) else { continue }
            if Self.keyMatches(
                binding: binding,
                eventKeyCode: keyCode,
                characters: chars,
                ignoring: ignoring
            ) {
                if shouldDeferHotkeys?() == true, !overlayToggleActions.contains(binding.action) {
                    return Unmanaged.passUnretained(event)
                }
                if Self.isEditingTextField() {
                    return Unmanaged.passUnretained(event)
                }
                emit(binding.action)
                return Unmanaged.passUnretained(event)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    /// Overlay open: pass keys through immediately unless they match overlay toggles.
    private func handleOverlayToggleTap(event: CGEvent, flags: CGEventFlags) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        var chars: String?
        var ignoring: String?
        if let ns = NSEvent(cgEvent: event) {
            chars = ns.characters
            ignoring = ns.charactersIgnoringModifiers
        }
        for binding in tapBindings where overlayToggleActions.contains(binding.action) {
            guard Self.flagsMatch(binding.flags, event: flags, isGrave: binding.isGrave) else { continue }
            if binding.isGrave {
                if Self.keyMatches(
                    binding: binding,
                    eventKeyCode: keyCode,
                    characters: chars,
                    ignoring: ignoring
                ) {
                    emit(binding.action)
                }
            } else if binding.keyCode == keyCode {
                emit(binding.action)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    /// True while a text field / field editor is first responder in the key window.
    public static func isEditingTextField() -> Bool {
        // CGEventTap / nested AppKit delivery runs on the main *thread* but often not on
        // the Swift MainActor *executor* — MainActor.assumeIsolated SEGV's there.
        guard Thread.isMainThread else { return false }
        return unsafeIsEditingTextFieldOnMainThread()
    }

    /// Caller must ensure main thread. Avoids MainActor executor checks.
    nonisolated private static func unsafeIsEditingTextFieldOnMainThread() -> Bool {
        // KVC avoids Swift MainActor isolation on NSApp.keyWindow (assumeIsolated crashes in taps).
        guard let app = NSApplication.shared as NSApplication? else { return false }
        let window = (app as AnyObject).value(forKey: "keyWindow") as? NSWindow
            ?? (app as AnyObject).value(forKey: "mainWindow") as? NSWindow
        guard let window else { return false }
        guard let fr = (window as AnyObject).value(forKey: "firstResponder") as? NSResponder else { return false }
        if fr is NSTextView || fr is NSTextField { return true }
        // SwiftUI field editor / nested responders.
        var node: NSResponder? = fr
        while let current = node {
            let name = NSStringFromClass(type(of: current))
            if name.contains("TextView") || name.contains("TextField") || name.contains("TextInput") {
                return true
            }
            node = current.nextResponder
        }
        return false
    }

    /// Exact modifier match; for grave also allow Option+Shift (shared `~/` keycap).
    private static func flagsMatch(_ binding: CGEventFlags, event: CGEventFlags, isGrave: Bool) -> Bool {
        if binding == event { return true }
        guard isGrave else { return false }
        let eventNoShift = event.subtracting(.maskShift)
        if binding == eventNoShift { return true }
        if binding.union(.maskShift) == event { return true }
        return false
    }

    private static func isGraveKey(_ key: String) -> Bool {
        let k = key.lowercased()
        return k == "`" || k == "grave" || k == "backtick" || k == "tilde"
    }

    private static func keyMatches(
        binding: TapBinding,
        eventKeyCode: Int64,
        characters: String?,
        ignoring: String?
    ) -> Bool {
        if binding.keyCode == eventKeyCode { return true }
        guard binding.isGrave else { return false }
        if Self.graveKeyCodes.contains(eventKeyCode) { return true }
        let chars = (ignoring ?? "") + (characters ?? "")
        // US `~`, BR quotes on the Esc-adjacent key, dead tilde/acute.
        let needles: [Character] = ["`", "~", "˜", "´", "'", "\"", "§", "±"]
        if chars.contains(where: { needles.contains($0) }) {
            // Only treat quote/section as grave when the hardware key is the Esc-adjacent one.
            if chars.contains("`") || chars.contains("~") || chars.contains("˜") {
                return true
            }
            return Self.graveKeyCodes.contains(eventKeyCode)
        }
        return false
    }

    /// ANSI grave=50, ISO section=10.
    private static let graveKeyCodes: Set<Int64> = [50, 10]

    private static let modifierMask: CGEventFlags = [
        .maskCommand, .maskShift, .maskAlternate, .maskControl
    ]

    public static func cgModifiers(_ names: [String]) -> CGEventFlags {
        var mods: CGEventFlags = []
        for name in names {
            switch name.lowercased() {
            case "command", "cmd": mods.insert(.maskCommand)
            case "option", "alt": mods.insert(.maskAlternate)
            case "shift": mods.insert(.maskShift)
            case "control", "ctrl": mods.insert(.maskControl)
            default: break
            }
        }
        return mods
    }

    // MARK: - Carbon

    private func registerCarbon(bindings: [HotkeyBinding]) {
        installHandlerIfNeeded()
        let target = GetApplicationEventTarget()
        for binding in bindings {
            let mods = Self.carbonModifiers(binding.modifiers)
            let codes = Self.keyCodes(for: binding.key)
            var modVariants: [UInt32] = [mods]
            // Grave shares a keycap with tilde — also register Option+Shift.
            if Self.isGraveKey(binding.key), mods & UInt32(shiftKey) == 0 {
                modVariants.append(mods | UInt32(shiftKey))
            }
            for keyCode in codes {
                for variant in modVariants {
                    var hotKeyRef: EventHotKeyRef?
                    let id = EventHotKeyID(signature: OSType(0x414C_574D), id: nextID)
                    let status = RegisterEventHotKey(keyCode, variant, id, target, 0, &hotKeyRef)
                    if status == noErr, let hotKeyRef {
                        hotKeys[nextID] = hotKeyRef
                        actionByID[nextID] = binding.action
                        nextID += 1
                    } else {
                        NSLog(
                            "ALWM: Carbon hotkey failed action=%@ key=%@ code=%u mods=%u status=%d",
                            binding.action, binding.key, keyCode, variant, status
                        )
                    }
                }
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData, let event else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if let action = manager.actionByID[hotKeyID.id] {
                    manager.emit(action)
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
    }

    public static func carbonModifiers(_ names: [String]) -> UInt32 {
        var mods: UInt32 = 0
        for name in names {
            switch name.lowercased() {
            case "command", "cmd": mods |= UInt32(cmdKey)
            case "option", "alt": mods |= UInt32(optionKey)
            case "shift": mods |= UInt32(shiftKey)
            case "control", "ctrl": mods |= UInt32(controlKey)
            default: break
            }
        }
        return mods
    }

    public static func keyCode(for key: String) -> UInt32? {
        keyCodes(for: key).first
    }

    public static func keyCodes(for key: String) -> [UInt32] {
        let k = key.lowercased()
        if isGraveKey(k) {
            return [50, 10]
        }
        let map: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "space": 49, "tab": 48, "return": 36, "escape": 53,
            ",": 43, "comma": 43, ".": 47, "period": 47,
            "-": 27, "minus": 27, "=": 24, "equal": 24, "plus": 24,
            "[": 33, "]": 30,
            "'": 39, "quote": 39, "apostrophe": 39
        ]
        if let code = map[k] { return [code] }
        return []
    }
}
