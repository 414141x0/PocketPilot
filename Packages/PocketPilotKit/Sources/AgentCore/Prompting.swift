/// Text renderings shared by every ``Pilot`` so models see the same world regardless of provider.
///
/// Coordinates are shown on a 1000×1000 grid; integers read more reliably to
/// language models than unit fractions. Use ``Point/init(grid:_:)`` to convert back.
extension Screen {
    /// Unlocated controls cost tokens without a way to target them directly, so only a few are listed.
    static let unlocatedLimit = 10

    /// A header line followed by one line per meaningful element, capped at `limit` elements:
    ///
    ///     screen=1290x2796 elements=2/2
    ///     [3] button "Send" @(850,910)
    ///     [4] textField "Message" = "hi" @(400,910) focused
    public func outline(limit: Int = 200) -> String {
        let meaningful = elements.filter(\.isMeaningful)
        let shown = meaningful.prefix(limit)
        var lines = ["screen=\(screenshot.width)x\(screenshot.height) elements=\(shown.count)/\(meaningful.count)"]
        lines += shown.map(\.outline)
        if meaningful.count > limit { lines.append("…+\(meaningful.count - limit) more") }
        if !unlocated.isEmpty {
            let shownUnlocated = unlocated.prefix(Self.unlocatedLimit)
            var line = "Also present, position unknown (may be off-screen; point at them if visible): " + shownUnlocated.joined(separator: ", ")
            if unlocated.count > shownUnlocated.count { line += " …+\(unlocated.count - shownUnlocated.count) more" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

extension Element {
    /// Elements with no label, value, or state tell a model nothing and only cost tokens.
    var isMeaningful: Bool {
        !label.isEmpty || !(value ?? "").isEmpty || !traits.isEmpty
    }

    /// `[id] role "label" = "value" @(x,y) flags`, with the value and flags only when present.
    public var outline: String {
        var line = "[\(id)] \(role.rawValue) \"\(label.truncated(to: 80))\""
        if let value, !value.isEmpty, value != label { line += " = \"\(value.truncated(to: 80))\"" }
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

extension Pilot {
    /// The system instructions every pilot gives its model.
    public static var instructions: String {
        """
        You operate an iPhone on the user's behalf. Each turn you see the goal, your previous \
        actions, a screenshot, and a list of on-screen accessibility elements. Reply with exactly one action.

        Actions, most useful first:
        - open "App": launch or switch to any app by name. Use it whenever the goal needs an app that \
        isn't already on screen.
        - press home: go to the Home Screen. Also press lock, volumeUp, volumeDown.
        - tap an element id or a grid point; long-press; scroll a direction; drag between two points.
        - type text into the focused field; key return, tab, escape, delete.
        - wait; done with a summary; giveUp with a reason.

        Elements look like `[12] button "Send" @(850,910)`: an id, role, label, optional value, \
        center on a 1000×1000 grid (x right, y down), and flags such as disabled or focused. \
        In the screenshot, each listed element is boxed and tagged with its id.

        - Target elements by id whenever one matches. For anything unboxed, such as an icon-only \
        button, tap its center as a grid point read from the screenshot.
        - To enter text, tap the field first, then type. Typing does not submit: use key return to \
        submit, tab for the next field, escape to dismiss, delete to erase one character.
        - If iOS asks whether to allow pasting, tap Allow Paste.
        - Scroll direction names where the content moves: "down" reveals what is below.
        - Drag from one point to another for sliders, maps, carousels, or pull-to-refresh.
        - To start or switch to any app, use open with its name, e.g. open "Settings". Never look for \
        app icons on the Home Screen or in the App Library.
        - If an action failed, read the reason and try something different rather than repeating it.
        - Finish with done and a one-sentence summary once the goal is met, or giveUp with the reason \
        when it cannot be met. Never ask the user questions.
        - Write your thought as three short parts: "Did: <what the last action achieved> Expect: <what \
        should change> Next: <this action and its target>". Each part at most 15 words.
        - End your thought with "Keep: <facts>" to remember short facts for later steps; they return as Remembered.
        - "The screen did not change" means your last action had no effect; choose a different target.
        """
    }
}

extension Step {
    /// The per-turn briefing: goal, recent history, and the element outline.
    ///
    /// Smaller limits suit models with small context windows.
    public func brief(historyLimit: Int = 20, elementLimit: Int = 200) -> String {
        var head = "Goal: \(goal)"
        if !mentionedApps.isEmpty {
            head += "\n\nApps in the goal: " + mentionedApps.map { "\"\($0)\"" }.joined(separator: ", ")
                + " (installed; reach them with open)"
        }
        if let remembered { head += "\n\nRemembered: \(remembered)" }
        return """
        \(head)

        Previous actions:
        \(historyOutline(limit: historyLimit))

        Screen:
        \(screen.outline(limit: elementLimit))
        """
    }

    /// The most recent `limit` turns, oldest first, one line each.
    public func historyOutline(limit: Int = .max) -> String {
        let recent = history.suffix(limit)
        guard !recent.isEmpty else { return "(none yet)" }
        return zip(recent.indices, recent).map { index, turn in
            var line = "\(index + 1). \(turn.decision.action)"
            if !turn.decision.thought.isEmpty { line += " — \(turn.decision.thought.truncated(to: 120))" }
            if let failure = turn.failure { line += " — failed: \(failure)" }
            return line
        }
        .joined(separator: "\n")
    }
}

extension Action: CustomStringConvertible {
    /// A compact rendering such as `tap [3]` or `scroll down`, read by models and people alike.
    public var description: String {
        switch self {
        case .tap(let target): "tap \(target)"
        case .longPress(let target): "long-press \(target)"
        case .scroll(let direction, nil): "scroll \(direction)"
        case .scroll(let direction, let target?): "scroll \(direction) in \(target)"
        case .drag(let from, let to): "drag \(from)->\(to)"
        case .type(let text): "type \"\(text.truncated(to: 80))\""
        case .press(let button): "press \(button)"
        case .key(let key): "key \(key)"
        case .open(let app): "open \(app)"
        case .wait(let seconds): "wait \(seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds))s"
        case .done(let summary): "done: \(summary)"
        case .giveUp(let reason): "give up: \(reason)"
        }
    }
}

extension Target: CustomStringConvertible {
    public var description: String {
        switch self {
        case .element(let id): "[\(id)]"
        case .point(let point): point.grid
        }
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
