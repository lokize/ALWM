import Foundation
import QuartzCore

public final class LayoutAnimator: @unchecked Sendable {
    public var duration: CFTimeInterval = 0.18
    private var displayLink: CVDisplayLink?
    private var startTime: CFTimeInterval = 0
    private var from: [WindowID: Rect] = [:]
    private var to: [WindowID: Rect] = [:]
    /// AX frame writes are expensive. Cap animation ticks at ~60 Hz even on
    /// 120/144 Hz displays so WindowServer/GPU are not flooded.
    private var lastAppliedAt: CFTimeInterval = 0
    /// Set on the CVDisplayLink thread to avoid waking the main queue at 144 Hz.
    nonisolated(unsafe) private var lastDispatchAt: CFTimeInterval = 0
    public var onFrame: (([WindowID: Rect], Double) -> Void)?
    public var onComplete: (([WindowID: Rect]) -> Void)?

    public init() {}

    public func animate(from: [WindowID: Rect], to: [WindowID: Rect]) {
        stop()
        self.from = from
        self.to = to
        if duration <= 0.001 {
            onComplete?(to)
            return
        }
        startTime = CACurrentMediaTime()
        lastAppliedAt = 0
        guard let link = ensureDisplayLink() else {
            onComplete?(to)
            return
        }
        if CVDisplayLinkStart(link) != kCVReturnSuccess {
            onComplete?(to)
        }
    }

    /// Reuse one display link for the process lifetime. Creating/destroying one per
    /// animation churns the WindowServer and can glitch high-refresh DisplayPort
    /// monitors.
    private func ensureDisplayLink() -> CVDisplayLink? {
        if let displayLink { return displayLink }
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return nil }
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context -> CVReturn in
            guard let context else { return kCVReturnSuccess }
            let animator = Unmanaged<LayoutAnimator>.fromOpaque(context).takeUnretainedValue()
            let now = CACurrentMediaTime()
            if now - animator.lastDispatchAt < 1.0 / 60.0 { return kCVReturnSuccess }
            animator.lastDispatchAt = now
            DispatchQueue.main.async {
                animator.tick()
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        displayLink = link
        return link
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if lastAppliedAt > 0, now - lastAppliedAt < 1.0 / 60.0 {
            return
        }
        lastAppliedAt = now
        let t = min(1, (now - startTime) / duration)
        let eased = 1 - pow(1 - t, 3)
        var current: [WindowID: Rect] = [:]
        for (id, end) in to {
            let start = from[id] ?? end
            current[id] = Rect(
                x: start.x + (end.x - start.x) * eased,
                y: start.y + (end.y - start.y) * eased,
                width: start.width + (end.width - start.width) * eased,
                height: start.height + (end.height - start.height) * eased
            )
        }
        onFrame?(current, t)
        if t >= 1 {
            // stop without finish — we invoke onComplete ourselves to avoid double-fire.
            let final = to
            stop(finish: false)
            onComplete?(final)
        }
    }

    /// Halt interpolation. When `finish` is true, snap to the destination frames first
    /// so callers never leave windows mid-lerp after an interrupt.
    public func stop(finish: Bool = false) {
        let shouldFinish = finish && displayLink != nil && !to.isEmpty
        let final = to
        let frameHandler = onFrame
        let completeHandler = onComplete
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        from.removeAll()
        to.removeAll()
        if shouldFinish {
            frameHandler?(final, 1)
            completeHandler?(final)
        }
    }

    deinit { stop(finish: false) }
}
