import AppKit
import SwiftUI

/// Walks up from a zero-size probe to find the SwiftUI-backed `NSScrollView`
/// (Form / ScrollView) and forces a legacy vertical scroller that stays visible.
struct ForceLegacyVerticalScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let probe = ScrollerProbeView()
        DispatchQueue.main.async { probe.apply() }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { (nsView as? ScrollerProbeView)?.apply() }
    }
}

private final class ScrollerProbeView: NSView {
    override var intrinsicContentSize: NSSize { .zero }
    override var isHidden: Bool {
        get { true }
        set {}
    }

    func apply() {
        var node: NSView? = self
        while let current = node {
            if let scroll = current as? NSScrollView {
                scroll.autohidesScrollers = false
                scroll.scrollerStyle = .legacy
                scroll.hasVerticalScroller = true
                scroll.verticalScroller?.isHidden = false
                scroll.verticalScroller?.alphaValue = 1
                scroll.tile()
                return
            }
            node = current.superview
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }
}

/// AppKit `NSScrollView` with **legacy** scrollers that never auto-hide.
/// Prefer SwiftUI `ScrollView` / `Form` + `ForceLegacyVerticalScroller` for panes
/// that use `Form` — nesting Form inside this view breaks trackpad scrolling.
struct MacAlwaysScrollView<Content: View>: NSViewRepresentable {
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content())
    }

    func makeNSView(context: Context) -> OverflowAwareScrollView {
        let scroll = OverflowAwareScrollView()
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .legacy
        scroll.scrollerKnobStyle = .default
        scroll.automaticallyAdjustsContentInsets = false
        scroll.usesPredominantAxisScrolling = true

        let hosting = ScrollForwardingHostingView(rootView: AnyView(content()))
        hosting.translatesAutoresizingMaskIntoConstraints = true

        let document = FlippedDocumentView(frame: .zero)
        document.addSubview(hosting)
        scroll.documentView = document

        context.coordinator.hosting = hosting
        context.coordinator.document = document
        context.coordinator.scrollView = scroll
        scroll.installTrackpadBridge()

        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipGeometryChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scroll.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.clipGeometryChanged(_:)),
            name: NSView.frameDidChangeNotification,
            object: scroll.contentView
        )

        DispatchQueue.main.async {
            context.coordinator.relayout(preserveScroll: false)
        }
        return scroll
    }

    func updateNSView(_ scroll: OverflowAwareScrollView, context: Context) {
        context.coordinator.content = content()
        context.coordinator.hosting?.rootView = AnyView(context.coordinator.content)
        scroll.forceLegacyScrollers()
        // Avoid relayout-on-every-SwiftUI-tick — it fights trackpad scrolling.
        context.coordinator.scheduleContentRelayout()
    }

    static func dismantleNSView(_ nsView: OverflowAwareScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        nsView.removeTrackpadBridge()
    }

    final class Coordinator: NSObject {
        var content: Content
        var hosting: ScrollForwardingHostingView?
        var document: FlippedDocumentView?
        weak var scrollView: OverflowAwareScrollView?
        private var lastClipSize: CGSize = .zero
        private var lastContentHeight: CGFloat = -1
        private var pendingRelayout: DispatchWorkItem?

        init(content: Content) {
            self.content = content
        }

        @objc func clipGeometryChanged(_ note: Notification) {
            guard let scroll = scrollView else { return }
            let size = scroll.contentView.bounds.size
            let widthChanged = abs(size.width - lastClipSize.width) > 0.5
            let heightChanged = abs(size.height - lastClipSize.height) > 0.5
            guard widthChanged || heightChanged else { return }
            lastClipSize = size
            relayout(preserveScroll: true)
        }

        func scheduleContentRelayout() {
            pendingRelayout?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.relayout(preserveScroll: true)
            }
            pendingRelayout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }

        func relayout(preserveScroll: Bool) {
            guard let scroll = scrollView,
                  let hosting,
                  let document
            else { return }

            let savedOrigin = scroll.contentView.bounds.origin
            let width = max(scroll.contentView.bounds.width, 1)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: 10_000)
            hosting.layoutSubtreeIfNeeded()
            let fitting = hosting.fittingSize
            let height = max(fitting.height, hosting.intrinsicContentSize.height, 1)

            // Skip no-op relayouts (same size) — prevents scroll position fights.
            if abs(height - lastContentHeight) < 0.5,
               abs(document.frame.width - width) < 0.5,
               preserveScroll {
                return
            }
            lastContentHeight = height

            document.frame = NSRect(x: 0, y: 0, width: width, height: height)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

            scroll.forceLegacyScrollers()
            if preserveScroll {
                let maxY = max(0, height - scroll.contentView.bounds.height)
                let y = min(max(0, savedOrigin.y), maxY)
                scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
            }
            scroll.reflectScrolledClipView(scroll.contentView)
            lastClipSize = scroll.contentView.bounds.size
        }
    }
}

/// Forwards trackpad/mouse wheel to the enclosing `NSScrollView`.
final class ScrollForwardingHostingView: NSHostingView<AnyView> {
    override func scrollWheel(with event: NSEvent) {
        if let scrollView = enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
        true
    }
}

final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        if let scrollView = enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class OverflowAwareScrollView: NSScrollView {
    private var trackpadMonitor: Any?

    func forceLegacyScrollers() {
        autohidesScrollers = false
        scrollerStyle = .legacy
        hasVerticalScroller = true
        hasHorizontalScroller = false
        verticalScroller?.isHidden = false
        verticalScroller?.alphaValue = 1
        horizontalScroller?.isHidden = true
    }

    /// When the cursor is over this scroll view, deliver trackpad wheel to *us*
    /// even if a nested SwiftUI view would otherwise swallow it.
    func installTrackpadBridge() {
        removeTrackpadBridge()
        trackpadMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.windowNumber == window.windowNumber else {
                return event
            }
            let local = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(local) else { return event }
            if let scroller = self.verticalScroller, !scroller.isHidden {
                let scrollerLocal = self.convert(local, to: scroller)
                if scroller.bounds.contains(scrollerLocal) {
                    return event
                }
            }
            self.scrollWheel(with: event)
            return nil
        }
    }

    func removeTrackpadBridge() {
        if let trackpadMonitor {
            NSEvent.removeMonitor(trackpadMonitor)
            self.trackpadMonitor = nil
        }
    }

    override func tile() {
        super.tile()
        forceLegacyScrollers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        forceLegacyScrollers()
        if window != nil {
            installTrackpadBridge()
        } else {
            removeTrackpadBridge()
        }
    }

    deinit {
        removeTrackpadBridge()
    }
}
