import Foundation
import QuartzCore

public final class LayoutAnimator: @unchecked Sendable {
    public var duration: CFTimeInterval = 0.18
    private var displayLink: CVDisplayLink?
    private var startTime: CFTimeInterval = 0
    private var from: [WindowID: Rect] = [:]
    private var to: [WindowID: Rect] = [:]
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
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else {
            onComplete?(to)
            return
        }
        displayLink = link
        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context -> CVReturn in
            guard let context else { return kCVReturnSuccess }
            let animator = Unmanaged<LayoutAnimator>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                animator.tick()
            }
            return kCVReturnSuccess
        }
        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
    }

    private func tick() {
        let t = min(1, (CACurrentMediaTime() - startTime) / duration)
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
            stop(finish: false)
            onComplete?(to)
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
        displayLink = nil
        if shouldFinish {
            frameHandler?(final, 1)
            completeHandler?(final)
        }
    }

    deinit { stop(finish: false) }
}
