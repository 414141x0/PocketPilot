/// Text renderings shared by every ``Pilot`` so models see the same world regardless of provider.
///
/// Coordinates are shown on a 1000×1000 grid; integers read more reliably to
/// language models than unit fractions. Use ``Point/init(grid:_:)`` to convert back.
extension Screen {
    /// A header line followed by one line per element, capped at `limit` elements:
    ///
    ///     screen=1290x2796 elements=2/2
    ///     [3] button "Send" @(850,910)
    ///     [4] textField "Message" = "hi" @(400,910) focused
    public func outline(limit: Int = 200) -> String {
        let shown = elements.prefix(limit)
        var lines = ["screen=\(screenshot.width)x\(screenshot.height) elements=\(shown.count)/\(elements.count)"]
        lines += shown.map(\.outline)
        if elements.count > limit { lines.append("…+\(elements.count - limit) more") }
        return lines.joined(separator: "\n")
    }
}

extension Element {
    /// `[id] role "label" = "value" @(x,y) flags`, with the value and flags only when present.
    public var outline: String {
        var line = "[\(id)] \(role.rawValue) \"\(label.truncated(to: 80))\""
        if let value, !value.isEmpty { line += " = \"\(value.truncated(to: 80))\"" }
        line += " @\(frame.center.grid)"
        if !traits.isEmpty { line += " " + traits.names.joined(separator: " ") }
        return line
    }
}

extension Element.Traits {
    var names: [String] {
        [(Self.disabled, "disabled"), (.selected, "selected"), (.focused, "focused")]
            .filter { contains($0.0) }
            .map(\.1)
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

extension String {
    func truncated(to length: Int) -> String {
        count > length ? prefix(length - 1) + "…" : self
    }
}
