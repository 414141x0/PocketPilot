/// Text renderings shared by every ``Pilot`` so models see the same world regardless of provider.
///
/// Coordinates are shown on a 1000×1000 grid; integers read more reliably to
/// language models than unit fractions. Use ``Point/init(grid:)`` to convert back.
extension Screen {
    /// One line per element: `[id] role "label" = "value" @(x,y)`.
    public var outline: String {
        elements.map(\.outline).joined(separator: "\n")
    }
}

extension Element {
    public var outline: String {
        var line = "[\(id)] \(role.rawValue) \"\(label)\""
        if let value, !value.isEmpty { line += " = \"\(value)\"" }
        return line + " @\(frame.center.grid)"
    }
}

extension Step {
    /// Prior turns, oldest first, one line each.
    public var historyOutline: String {
        history.enumerated().map { index, turn in
            var line = "\(index + 1). \(turn.decision.action)"
            if let failure = turn.failure { line += " — failed: \(failure)" }
            return line
        }
        .joined(separator: "\n")
    }
}

extension Point {
    public init(grid x: Int, _ y: Int) {
        self.init(x: Double(x) / 1000, y: Double(y) / 1000)
    }

    var grid: String { "(\(Int((x * 1000).rounded())),\(Int((y * 1000).rounded())))" }
}
