import AppKit
import SwiftUI

@MainActor
public final class NotepadController {
    public private(set) var isVisible = false
    public let store = NotesStore()

    public var onClose: (() -> Void)?
    public var onVisibilityChanged: ((Bool) -> Void)?

    private var panel: NSPanel?
    private var blurPanel: NSWindow?
    private weak var blurTintView: NSView?
    private var hosting: NSHostingController<NotepadRootView>?
    private var presentationGeneration: UInt64 = 0
    private var currentMonitor: MonitorInfo?

    public init() {}

    public func toggle(settings: NotepadSettings, monitor: MonitorInfo) {
        guard settings.enabled else { return }
        if isVisible {
            hide(settings: settings, monitor: monitor)
        } else {
            show(settings: settings, monitor: monitor)
        }
    }

    public func show(settings: NotepadSettings, monitor: MonitorInfo, pageID: UUID? = nil) {
        guard settings.enabled else { return }
        if let pageID {
            store.openTab(pageID)
        } else if store.activePageID == nil {
            if store.index.pages.isEmpty {
                _ = store.createPage()
            } else if let first = store.filteredSummaries().first {
                store.openTab(first.id)
            }
        }
        currentMonitor = monitor
        ensurePanel(settings: settings, monitor: monitor)
        animate(toVisible: true, settings: settings, monitor: monitor)
    }

    public func openNew(settings: NotepadSettings, monitor: MonitorInfo) {
        _ = store.createPage()
        show(settings: settings, monitor: monitor)
    }

    public func open(pageID: UUID, settings: NotepadSettings, monitor: MonitorInfo) {
        store.openTab(pageID)
        show(settings: settings, monitor: monitor, pageID: pageID)
    }

    public func hide(settings: NotepadSettings, monitor: MonitorInfo) {
        guard isVisible else { return }
        store.flushPendingSaves()
        animate(toVisible: false, settings: settings, monitor: monitor)
    }

    public func panelFrame(settings: NotepadSettings, monitor: MonitorInfo, visible: Bool) -> NSRect {
        let rect = visible
            ? QuakePanelGeometry.visibleFrame(settings: settings, monitor: monitor)
            : QuakePanelGeometry.hiddenFrame(settings: settings, monitor: monitor)
        let mainH = Double(NSScreen.screens.first?.frame.height ?? monitor.frame.height + monitor.frame.y)
        return rect.cocoaRect(mainHeight: mainH)
    }

    public func refreshLayout(settings: NotepadSettings, monitor: MonitorInfo, visible: Bool, frame: NSRect? = nil) {
        currentMonitor = monitor
        let target = frame ?? panelFrame(settings: settings, monitor: monitor, visible: visible)
        panel?.setFrame(target, display: true)
        updateBlur(settings: settings, frame: target, monitor: monitor, visible: visible)
    }

    public func containsClick(at cocoaPoint: NSPoint, settings: NotepadSettings, monitor: MonitorInfo) -> Bool {
        guard isVisible, let panel else { return false }
        return panel.frame.contains(cocoaPoint)
    }

    public var isKeyWindow: Bool {
        panel?.isKeyWindow ?? false
    }

    public func restoreKeyboardFocus() {
        guard isVisible, let panel else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, let panel = self.panel else { return }
            if let input = Self.findTextInput(in: panel.contentView) {
                panel.makeFirstResponder(input)
            } else {
                panel.makeFirstResponder(self.hosting?.view)
            }
        }
    }

    private static func findTextInput(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.acceptsFirstResponder {
            let name = NSStringFromClass(type(of: view))
            if view is NSTextView || view is NSTextField { return view }
            if name.contains("TextView") || name.contains("TextField")
                || name.contains("TextEditor") || name.contains("FieldEditor")
                || name.contains("TextInput") {
                return view
            }
        }
        for sub in view.subviews.reversed() {
            if let found = findTextInput(in: sub) { return found }
        }
        return nil
    }

    private func ensurePanel(settings: NotepadSettings, monitor: MonitorInfo) {
        if panel != nil, hosting != nil { return }

        let visible = panelFrame(settings: settings, monitor: monitor, visible: true)
        // Must become key so SwiftUI TextField / TextEditor receive typing.
        // `.nonactivatingPanel` blocks that (Quake keeps it on purpose; notepad cannot).
        let p = NotepadKeyPanel(
            contentRect: visible,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = false

        let root = NotepadRootView(store: store, onClose: { [weak self] in
            self?.onClose?()
        })
        let host = NSHostingController(rootView: root)
        host.view.wantsLayer = true
        host.view.layer?.cornerRadius = 12
        host.view.layer?.masksToBounds = true
        p.contentViewController = host
        panel = p
        hosting = host
    }

    private func animate(toVisible: Bool, settings: NotepadSettings, monitor: MonitorInfo) {
        presentationGeneration &+= 1
        let gen = presentationGeneration
        ensurePanel(settings: settings, monitor: monitor)
        guard let panel else { return }

        isVisible = toVisible
        onVisibilityChanged?(toVisible)

        let target = panelFrame(settings: settings, monitor: monitor, visible: toVisible)
        updateBlur(settings: settings, frame: target, monitor: monitor, visible: toVisible)

        let duration = max(0, settings.animationDuration)
        if duration <= 0.01 {
            panel.setFrame(target, display: true)
            finishVisibility(toVisible, gen: gen)
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.finishVisibility(toVisible, gen: gen)
            }
        }
    }

    private func finishVisibility(_ visible: Bool, gen: UInt64) {
        guard gen == presentationGeneration else { return }
        isVisible = visible
        if visible {
            panel?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            panel?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isVisible, let panel = self.panel else { return }
                if let input = Self.findTextInput(in: panel.contentView) {
                    panel.makeFirstResponder(input)
                } else {
                    panel.makeFirstResponder(self.hosting?.view)
                }
            }
        } else {
            panel?.orderOut(nil)
            blurPanel?.orderOut(nil)
        }
    }

    private func updateBlur(settings: NotepadSettings, frame: NSRect, monitor: MonitorInfo, visible: Bool) {
        guard settings.blur, visible else {
            blurPanel?.orderOut(nil)
            return
        }
        if blurPanel == nil {
            let w = NSWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) - 1)
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            let tint = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
            tint.material = .hudWindow
            tint.state = .active
            tint.blendingMode = .behindWindow
            tint.wantsLayer = true
            tint.layer?.cornerRadius = 12
            tint.autoresizingMask = [.width, .height]
            let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
            root.addSubview(tint)
            w.contentView = root
            blurTintView = tint
            blurPanel = w
        }
        blurTintView?.alphaValue = CGFloat(min(1, max(0.05, settings.blurIntensity)))
        blurPanel?.setFrame(frame, display: true)
        blurPanel?.orderFrontRegardless()
    }
}

/// Borderless floating panel that still accepts keyboard focus (search + editor).
private final class NotepadKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private extension Rect {
    func cocoaRect(mainHeight: Double) -> NSRect {
        NSRect(
            x: x,
            y: mainHeight - y - height,
            width: width,
            height: height
        )
    }
}
