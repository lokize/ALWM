import AppKit
import Foundation

/// Full-screen dimmed overlay for drag-selecting a capture rectangle (Cocoa coords).
@MainActor
final class CaptureSelectionOverlay {
    enum Result {
        case cancelled
        case region(NSRect) // global Cocoa coords (bottom-left origin, spans screens)
        case fullDisplay(NSScreen)
    }

    private var windows: [NSWindow] = []
    private var completion: ((Result) -> Void)?
    private var keyMonitor: Any?
    private var finished = false
    private var keyMonitorBridge: CaptureOverlayKeyBridge?

    func present(completion: @escaping (Result) -> Void) {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        removeKeyMonitor()
        finished = false
        self.completion = completion

        let hint = L10n.t("capture.overlay.hint")
        var keyWin: NSWindow?
        for screen in NSScreen.screens {
            let win = CaptureOverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.level = .screenSaver
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            win.ignoresMouseEvents = false
            win.acceptsMouseMovedEvents = true
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.screenFrame = screen.frame
            view.hintText = hint
            view.onResult = { [weak self] result in
                Task { @MainActor in self?.finish(result) }
            }
            win.contentView = view
            win.orderFrontRegardless()
            windows.append(win)
            if screen.frame.contains(NSEvent.mouseLocation) {
                keyWin = win
            }
        }
        let focus = keyWin ?? windows.first
        focus?.makeKeyAndOrderFront(nil)
        if let focus, let view = focus.contentView as? SelectionView {
            focus.makeFirstResponder(view)
        }
        NSApp.activate(ignoringOtherApps: true)

        // Borderless + LSUIElement often never delivers keyDown to the view — local monitor is reliable.
        let bridge = CaptureOverlayKeyBridge(
            onCancel: { [weak self] in
                Task { @MainActor in self?.finish(.cancelled) }
            },
            onFullDisplay: { [weak self] in
                Task { @MainActor in
                    let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                        ?? NSScreen.main
                        ?? NSScreen.screens.first
                    if let screen {
                        self?.finish(.fullDisplay(screen))
                    } else {
                        self?.finish(.cancelled)
                    }
                }
            }
        )
        keyMonitorBridge = bridge
        keyMonitor = bridge.install()
    }

    func cancelActive() {
        finish(.cancelled)
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        keyMonitorBridge = nil
    }

    private func finish(_ result: Result) {
        guard !finished else { return }
        finished = true
        removeKeyMonitor()
        let cb = completion
        completion = nil
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        cb?(result)
    }
}

/// Borderless overlay must become key for Esc/Enter.
private final class CaptureOverlayWindow: NSWindow {
    nonisolated override var canBecomeKey: Bool { true }
    nonisolated override var canBecomeMain: Bool { true }
}

/// Local key monitor; AppKit callback stays nonisolated.
private final class CaptureOverlayKeyBridge: @unchecked Sendable {
    private let onCancel: () -> Void
    private let onFullDisplay: () -> Void

    init(onCancel: @escaping () -> Void, onFullDisplay: @escaping () -> Void) {
        self.onCancel = onCancel
        self.onFullDisplay = onFullDisplay
    }

    func install() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53:
                self.onCancel()
                return nil
            case 36, 76:
                self.onFullDisplay()
                return nil
            default:
                return event
            }
        }
    }
}

/// Selection overlay — AppKit overrides are nonisolated; only touch unsafe state.
private final class SelectionView: NSView {
    nonisolated(unsafe) var screenFrame: NSRect = .zero
    nonisolated(unsafe) var hintText: String = ""
    nonisolated(unsafe) var onResult: ((CaptureSelectionOverlay.Result) -> Void)?
    nonisolated(unsafe) private var dragStart: NSPoint?
    nonisolated(unsafe) private var dragCurrent: NSPoint?

    nonisolated override var acceptsFirstResponder: Bool { true }

    nonisolated override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        if let start = dragStart, let current = dragCurrent {
            let r = NSRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            r.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 2
            path.stroke()
        }

        let hint = hintText
        guard !hint.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let size = (hint as NSString).size(withAttributes: attrs)
        let origin = NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 48)
        (hint as NSString).draw(at: origin, withAttributes: attrs)
    }

    nonisolated override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    nonisolated override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    nonisolated override func mouseUp(with event: NSEvent) {
        defer {
            dragStart = nil
            dragCurrent = nil
            needsDisplay = true
        }
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        let local = NSRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
        if local.width < 4 || local.height < 4 {
            return
        }
        let global = NSRect(
            x: screenFrame.origin.x + local.origin.x,
            y: screenFrame.origin.y + local.origin.y,
            width: local.width,
            height: local.height
        )
        onResult?(.region(global))
    }

    nonisolated override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            onResult?(.cancelled)
        case 36, 76:
            let frame = screenFrame
            let screen = NSScreen.screens.first(where: { $0.frame == frame })
                ?? NSScreen.main
            if let screen {
                onResult?(.fullDisplay(screen))
            } else {
                onResult?(.cancelled)
            }
        default:
            break
        }
    }
}
