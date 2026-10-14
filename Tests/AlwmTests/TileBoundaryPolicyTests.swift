import Testing
@testable import Alwm

@Suite("Tile boundary policy")
struct TileBoundaryPolicyTests {
    @Test("a small outer gap cannot be consumed by bottom overflow tolerance")
    func configuredOuterGapIsPreserved() {
        let screenBottom = 800.0
        let outerGap = 7.15
        let usableBottom = screenBottom - outerGap

        #expect(TileBoundaryPolicy.exceedsBottomBoundary(
            frameMaxY: screenBottom,
            usableMaxY: usableBottom,
            outerGap: outerGap
        ))
    }

    @Test("bottom tolerance scales below very small configured gaps")
    func toleranceCannotConsumeSmallGap() {
        #expect(TileBoundaryPolicy.bottomOverflowTolerance(outerGap: 0) == 0)
        #expect(TileBoundaryPolicy.bottomOverflowTolerance(outerGap: 0.4) == 0.1)
        #expect(TileBoundaryPolicy.bottomOverflowTolerance(outerGap: 12) == 1)
    }
}
