import Foundation

enum TileBoundaryPolicy {
    // Accessibility frame readback can differ slightly from the requested geometry.
    // Keep this tolerance smaller than the configured outer gap so it cannot erase it.
    static func bottomOverflowTolerance(outerGap: Double) -> Double {
        min(1, max(0, outerGap * 0.25))
    }

    static func exceedsBottomBoundary(frameMaxY: Double, usableMaxY: Double, outerGap: Double) -> Bool {
        frameMaxY > usableMaxY + bottomOverflowTolerance(outerGap: outerGap)
    }
}
