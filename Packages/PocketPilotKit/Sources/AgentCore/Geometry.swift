/// A location on screen in unit coordinates: `(0, 0)` is top-left, `(1, 1)` is bottom-right.
///
/// Unit space keeps every layer resolution-independent: models reason in it,
/// the accessibility tree reports in it, and HID touch events consume it directly.
public struct Point: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x.clamped(to: 0...1)
        self.y = y.clamped(to: 0...1)
    }
}

/// An axis-aligned rectangle in unit coordinates.
public struct Rect: Sendable, Hashable, Codable {
    public var origin: Point
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = Point(x: x, y: y)
        self.width = width
        self.height = height
    }

    public var center: Point { Point(x: origin.x + width / 2, y: origin.y + height / 2) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Whether this rectangle contains `point` (unit coordinates), optionally padded by `margin`.
    public func contains(_ point: Point, margin: Double = 0) -> Bool {
        point.x >= (origin.x - margin) && point.x <= (origin.x + width + margin) &&
        point.y >= (origin.y - margin) && point.y <= (origin.y + height + margin)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
