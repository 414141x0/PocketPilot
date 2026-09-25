/// Something the agent chooses to do next.
///
/// Actions are phrased the way a model thinks ("tap the Send button", "scroll down").
/// The ``Agent`` resolves them into concrete ``Gesture``s against the current screen.
public enum Action: Sendable, Hashable, Codable {
    case tap(Target)
    case longPress(Target)
    case scroll(Direction, in: Target? = nil)
    /// A finger dragged from one target to another: sliders, maps, carousels, pull-to-refresh.
    case drag(from: Target, to: Target)
    /// Types into the focused field; `replacing` clears existing text first (select all, delete, type).
    case type(String, replacing: Bool)
    case press(HardwareButton)
    /// Presses an editing key on the keyboard, for example Return to submit a field.
    case key(KeyboardKey)
    /// Opens an app by display name ("Settings") or bundle identifier.
    case open(app: String)
    case wait(seconds: Double)
    /// The goal is achieved; `summary` is reported back to the user.
    case done(summary: String)
    /// The goal cannot be achieved; `reason` is reported back to the user.
    case giveUp(reason: String)

    /// Whether this action ends the run.
    public var isTerminal: Bool {
        switch self {
        case .done, .giveUp: true
        default: false
        }
    }
}

/// Where an action lands: an accessibility element when one is known, otherwise a raw point.
public enum Target: Sendable, Hashable, Codable {
    case element(Element.ID)
    case point(Point)
}

public enum Direction: String, Sendable, Hashable, Codable, CaseIterable {
    case up, down, left, right
}

public enum HardwareButton: String, Sendable, Hashable, Codable, CaseIterable {
    case home, lock, volumeUp, volumeDown
}

public enum KeyboardKey: String, Sendable, Hashable, Codable, CaseIterable {
    case `return`, tab, escape, delete
}

/// A device-level input with every target resolved to coordinates.
public enum Gesture: Sendable, Hashable {
    case tap(Point)
    case longPress(Point, duration: Duration = .seconds(1))
    case swipe(from: Point, to: Point, duration: Duration = .milliseconds(300))
    case type(String)
    /// Selects all text in the focused field (Command-A), the first step of replacing field text.
    case selectAll
    case press(HardwareButton)
    case key(KeyboardKey)
    case launch(bundleID: String)
}
