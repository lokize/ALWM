import Foundation

/// Geometry helpers using top-left origin (AppKit / AX style on macOS).
public struct Rect: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var origin: (x: Double, y: Double) { (x, y) }
    public var size: (width: Double, height: Double) { (width, height) }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func insetBy(dx: Double, dy: Double) -> Rect {
        Rect(x: x + dx, y: y + dy, width: max(0, width - dx * 2), height: max(0, height - dy * 2))
    }

    public func contains(pointX: Double, pointY: Double) -> Bool {
        pointX >= x && pointX < maxX && pointY >= y && pointY < maxY
    }

    /// Keep the rect inside `bounds` (top-left origin), shrinking if needed.
    public func clamped(to bounds: Rect, minWidth: Double = 48, minHeight: Double = 48) -> Rect {
        var r = self
        let capW = max(minWidth, bounds.width)
        let capH = max(minHeight, bounds.height)
        r.width = min(max(minWidth, r.width), capW)
        r.height = min(max(minHeight, r.height), capH)
        if r.x < bounds.x { r.x = bounds.x }
        if r.y < bounds.y { r.y = bounds.y }
        if r.maxX > bounds.maxX { r.x = bounds.maxX - r.width }
        if r.maxY > bounds.maxY { r.y = bounds.maxY - r.height }
        if r.x < bounds.x {
            r.x = bounds.x
            r.width = capW
        }
        if r.y < bounds.y {
            r.y = bounds.y
            r.height = capH
        }
        if r.maxX > bounds.maxX {
            r.x = bounds.x
            r.width = capW
        }
        if r.maxY > bounds.maxY {
            r.y = bounds.y
            r.height = capH
        }
        return r
    }
}

extension Rect: CustomStringConvertible {
    public var description: String {
        "(\(Int(x)),\(Int(y)) \(Int(width))x\(Int(height)))"
    }
}

public struct Size: Equatable, Sendable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public enum Direction: String, Sendable, Codable {
    case left, right, up, down
}
