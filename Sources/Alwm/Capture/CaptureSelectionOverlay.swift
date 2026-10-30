import AppKit
import Foundation

/// Full-screen dimmed overlay for drag-selecting a capture rectangle (Cocoa coords).
@MainActor
final class CaptureSelectionOverlay {
    enum Result {
        case cancelled
        case region(NSRect) // global Cocoa coords (bottom-left origin, spans screens)
        case fullDisplay(NSScreen)
        case window(CaptureWindowTarget)
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

/// Selection overlay — drag selects a region, click picks the window underneath, Enter = full display.
private final class SelectionView: NSView {
    var screenFrame: NSRect = .zero
    var hintText: String = ""
    var onResult: ((CaptureSelectionOverlay.Result) -> Void)?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var dragMoved = false
    private var hoverTarget: CaptureWindowTarget?
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func globalPoint(for event: NSEvent) -> NSPoint {
        let local = convert(event.locationInWindow, from: nil)
        return NSPoint(x: screenFrame.minX + local.x, y: screenFrame.minY + local.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        if let start = dragStart, let current = dragCurrent, dragMoved {
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
        } else if let target = hoverTarget {
            drawWindowHighlight(target)
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

    private func drawWindowHighlight(_ target: CaptureWindowTarget) {
        let local = NSRect(
            x: target.frame.minX - screenFrame.minX,
            y: target.frame.minY - screenFrame.minY,
            width: target.frame.width,
            height: target.frame.height
        )
        let clipped = local.intersection(bounds)
        guard !clipped.isEmpty else { return }

        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setFill()
        clipped.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        NSColor.systemBlue.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath(rect: clipped.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()

        guard !target.title.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let title = "\(target.title)  \(Int(target.frame.width))×\(Int(target.frame.height))"
        let textSize = (title as NSString).size(withAttributes: attrs)
        var label = NSRect(
            x: clipped.minX + 6,
            y: clipped.maxY - textSize.height - 6,
            width: textSize.width + 12,
            height: textSize.height + 6
        )
        label.origin.x = max(bounds.minX + 4, min(label.origin.x, bounds.maxX - label.width - 4))
        label.origin.y = max(bounds.minY + 4, min(label.origin.y, bounds.maxY - label.height - 4))
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: label, xRadius: 4, yRadius: 4).fill()
        (title as NSString).draw(
            at: NSPoint(x: label.minX + 6, y: label.minY + 3),
            withAttributes: attrs
        )
    }

    override func mouseMoved(with event: NSEvent) {
        guard dragStart == nil else { return }
        let target = CaptureWindowFinder.window(atGlobalCocoaPoint: globalPoint(for: event))
        if target?.id != hoverTarget?.id {
            hoverTarget = target
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard dragStart == nil, hoverTarget != nil else { return }
        hoverTarget = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        dragMoved = false
        hoverTarget = CaptureWindowFinder.window(atGlobalCocoaPoint: globalPoint(for: event))
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragCurrent = point
        if let start = dragStart, abs(point.x - start.x) > 4 || abs(point.y - start.y) > 4 {
            dragMoved = true
            hoverTarget = nil
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let moved = dragMoved
        defer {
            dragStart = nil
            dragCurrent = nil
            dragMoved = false
            needsDisplay = true
        }
        guard let start = dragStart else { return }

        // A click (no drag) picks the window underneath. Dragging keeps selecting a region.
        if !moved {
            let target = CaptureWindowFinder.window(atGlobalCocoaPoint: globalPoint(for: event))
                ?? hoverTarget
            if let target {
                onResult?(.window(target))
            }
            return
        }

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

    override func keyDown(with event: NSEvent) {
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
