import Foundation

/// Enforces read-only safety policy during an agent run.
///
/// Refuses actions that mutate or could mutate device state:
/// - Typing and keyboard key presses
/// - Dragging and long pressing
/// - Volume and lock hardware buttons (home is allowed for navigation)
/// - Tapping elements with mutating roles: toggle, textField, keyboardKey, slider (including pickers/steppers)
/// - Tapping elements with mutating labels (whole-word matching): Save, Done, ✓, Delete, Remove, Edit, Add, +, Send, Buy, Confirm, Allow, Clear, Reset, etc.
/// - Tapping predictive-bar words or keyboard area elements when a keyboard is active
/// - Point-taps landing inside the bounding frame of any forbidden element
/// - Scrolling inside sliders or pickers
public enum ReadOnlyPolicy {
    /// Mutating words that, when appearing as whole words in an element's label, indicate a mutating action.
    public static let mutatingKeywords: Set<String> = [
        "save", "done", "delete", "remove", "edit", "add", "send",
        "buy", "purchase", "confirm", "allow", "clear", "reset",
        "create", "compose", "repeat", "toggle", "switch", "enable", "disable"
    ]

    /// Symbols indicating mutation when used as an action label.
    public static let mutatingSymbols: Set<String> = ["+", "✓"]

    /// Checks whether `action` should be refused in read-only mode, returning a failure explanation if so.
    public static func refusal(for action: Action, on screen: Screen) -> String? {
        switch action {
        case .type:
            return "Typing is forbidden in read-only mode."

        case .drag:
            return "Dragging is forbidden in read-only mode."

        case .longPress:
            return "Long press is forbidden in read-only mode."

        case .key(let key):
            return "Keyboard key press '\(key.rawValue)' is forbidden in read-only mode."

        case .press(let button):
            if button != .home {
                return "Hardware button '\(button.rawValue)' is forbidden in read-only mode."
            }
            return nil

        case .tap(let target):
            return refusalForTap(on: target, screen: screen)

        case .scroll(_, let target):
            return refusalForScroll(on: target, screen: screen)

        case .open, .wait, .done, .giveUp:
            return nil
        }
    }

    /// Checks if a tap target hits a mutating element or falls within one.
    private static func refusalForTap(on target: Target, screen: Screen) -> String? {
        switch target {
        case .element(let id):
            guard let element = screen[id] else { return nil }
            return refusalReason(for: element, screen: screen)

        case .point(let point):
            // Check if point lands inside any element that is forbidden
            for element in screen.elements {
                if element.frame.contains(point), let reason = refusalReason(for: element, screen: screen) {
                    return "Tapping at (\(point.x), \(point.y)) lands inside forbidden element '\(element.label)': \(reason)"
                }
            }
            // Check if keyboard is visible and point is in the keyboard / predictive area (unless landing on a tab)
            if isKeyboardVisible(on: screen) && point.y >= 0.50 {
                if screen.elements.contains(where: { $0.role == .tab && $0.frame.contains(point) }) {
                    return nil
                }
                return "Tapping in the keyboard or predictive bar area is forbidden in read-only mode."
            }
            return nil
        }
    }

    /// Checks if scrolling is targeted inside a slider or picker.
    private static func refusalForScroll(on target: Target?, screen: Screen) -> String? {
        guard let target else { return nil }
        switch target {
        case .element(let id):
            if let element = screen[id], element.role == .slider {
                return "Scrolling in slider '\(element.label)' is forbidden in read-only mode."
            }
        case .point(let point):
            if let element = screen.elements.first(where: { $0.role == .slider && $0.frame.contains(point) }) {
                return "Scrolling in slider '\(element.label)' is forbidden in read-only mode."
            }
        }
        return nil
    }

    /// Determines if an element represents a mutating UI control in read-only mode.
    public static func refusalReason(for element: Element, screen: Screen) -> String? {
        // Headers are non-interactive titles and never mutate
        if element.role == .header {
            return nil
        }

        // 1. Role-based checks
        switch element.role {
        case .toggle:
            return "Toggling '\(element.label)' is forbidden in read-only mode."
        case .textField:
            return "Interacting with text field '\(element.label)' is forbidden in read-only mode."
        case .keyboardKey:
            return "Keyboard keys are forbidden in read-only mode."
        case .slider:
            return "Adjusting slider '\(element.label)' is forbidden in read-only mode."
        default:
            break
        }

        // 2. Predictive bar / keyboard area check (tabs are excluded as navigation)
        if isKeyboardVisible(on: screen) && element.frame.center.y >= 0.50 && element.role != .tab {
            return "Interacting with keyboard/predictive element '\(element.label)' is forbidden in read-only mode."
        }

        // 3. Mutating label checks
        let trimmed = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if mutatingSymbols.contains(trimmed) {
            return "Action '\(element.label)' is forbidden in read-only mode."
        }

        let words = element.label.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for word in words {
            if mutatingKeywords.contains(word) {
                return "Action '\(element.label)' (contains '\(word)') is forbidden in read-only mode."
            }
        }

        return nil
    }

    /// Whether an on-screen keyboard is currently visible.
    public static func isKeyboardVisible(on screen: Screen) -> Bool {
        screen.elements.contains { $0.role == .keyboardKey || $0.traits.contains(.focused) }
    }

    /// Whether a gesture is mutating (used to sanitize preparation gestures).
    public static func isMutating(gesture: Gesture) -> Bool {
        switch gesture {
        case .press(let button):
            return button != .home
        case .type, .selectAll, .key:
            return true
        case .tap, .swipe, .longPress, .launch:
            return false
        }
    }
}
