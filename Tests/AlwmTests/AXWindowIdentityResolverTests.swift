import Testing
@testable import Alwm

@Suite("Accessibility window identity resolution")
struct AXWindowIdentityResolverTests {
    @Test("a popup cannot inherit a sibling window ID from WindowServer ordering")
    func rejectsUnmatchedPopupInsteadOfTakingFirstWindowID() {
        let candidates = [
            CGWindowSnapshot(
                windowNumber: 14894,
                frame: Rect(x: 783, y: 1476, width: 66, height: 20),
                layer: 0
            ),
            CGWindowSnapshot(
                windowNumber: 14640,
                frame: Rect(x: 774, y: 1470, width: 1920, height: 1050),
                layer: 0
            )
        ]

        #expect(AXWindowIdentityResolver.matchingWindowNumber(
            for: Rect(x: 774, y: 1470, width: 1920, height: 1050),
            candidates: candidates,
            excluding: []
        ) == 14640)

        #expect(AXWindowIdentityResolver.matchingWindowNumber(
            for: Rect(x: 2200, y: 0, width: 280, height: 250),
            candidates: candidates,
            excluding: [14640]
        ) == nil)
    }

    @Test("a resolved WindowServer ID is not assigned to two AX elements")
    func excludesAlreadyMatchedWindowNumbers() {
        let candidate = CGWindowSnapshot(
            windowNumber: 42,
            frame: Rect(x: 10, y: 20, width: 800, height: 600),
            layer: 0
        )

        #expect(AXWindowIdentityResolver.matchingWindowNumber(
            for: candidate.frame,
            candidates: [candidate],
            excluding: [42]
        ) == nil)
    }
}
