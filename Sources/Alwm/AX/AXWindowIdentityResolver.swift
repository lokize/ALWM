import Foundation

struct CGWindowSnapshot: Sendable {
    let windowNumber: Int
    let frame: Rect
    let layer: Int
}

/// Associates AX windows without AXWindowNumber only when their geometry identifies
/// one on-screen WindowServer window. List ordering is not stable across APIs.
enum AXWindowIdentityResolver {
    static func matchingWindowNumber(
        for frame: Rect,
        candidates: [CGWindowSnapshot],
        excluding usedWindowNumbers: Set<Int>
    ) -> Int? {
        guard frame.x.isFinite, frame.y.isFinite, frame.width >= 40, frame.height >= 40 else {
            return nil
        }

        let matches = candidates.compactMap { candidate -> (number: Int, score: Double)? in
            guard !usedWindowNumbers.contains(candidate.windowNumber),
                  candidate.layer == 0,
                  candidate.frame.width >= 40,
                  candidate.frame.height >= 40
            else { return nil }

            let cg = candidate.frame
            let xTolerance = max(32, frame.width * 0.02)
            let yTolerance = max(32, frame.height * 0.02)
            let widthTolerance = max(32, frame.width * 0.03)
            let heightTolerance = max(32, frame.height * 0.03)
            let dx = abs(frame.x - cg.x)
            let dy = abs(frame.y - cg.y)
            let dw = abs(frame.width - cg.width)
            let dh = abs(frame.height - cg.height)
            guard dx <= xTolerance, dy <= yTolerance,
                  dw <= widthTolerance, dh <= heightTolerance
            else { return nil }

            let score = dx / xTolerance + dy / yTolerance
                + dw / widthTolerance + dh / heightTolerance
            return (candidate.windowNumber, score)
        }.sorted { $0.score < $1.score }

        guard let best = matches.first else { return nil }
        // If two CG windows are indistinguishable geometrically, guessing risks
        // binding a transient AX element to an unrelated document window.
        if matches.count > 1, abs(matches[1].score - best.score) < 0.25 { return nil }
        return best.number
    }
}
