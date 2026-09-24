/// What the agent perceives at one moment: pixels plus, when available, accessibility semantics.
public struct Screen: Sendable {
    public var screenshot: Screenshot
    public var elements: [Element]
    /// Controls the device reports but whose position is unknown, such as icon-only buttons.
    /// Pilots reach them by pointing at the screenshot.
    public var unlocated: [String]

    public init(screenshot: Screenshot, elements: [Element] = [], unlocated: [String] = []) {
        self.screenshot = screenshot
        self.elements = elements
        self.unlocated = unlocated
    }

    public subscript(id: Element.ID) -> Element? {
        elements.first { $0.id == id }
    }
}

/// One accessibility element, flattened out of the device's accessibility hierarchy.
public struct Element: Sendable, Hashable, Identifiable, Codable {
    /// Stable only within a single ``Screen``.
    public var id: Int
    public var role: Role
    public var label: String
    public var value: String?
    public var frame: Rect
    public var traits: Traits

    public init(id: Int, role: Role, label: String, value: String? = nil, frame: Rect, traits: Traits = []) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
        self.traits = traits
    }

    public enum Role: String, Sendable, Hashable, Codable {
        case button, link, text, textField, image, toggle, slider, tab, cell, header, keyboardKey, other
    }

    /// The state flags a model needs to choose correctly between otherwise similar elements.
    public struct Traits: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let disabled = Traits(rawValue: 1 << 0)
        public static let selected = Traits(rawValue: 1 << 1)
        public static let focused = Traits(rawValue: 1 << 2)
    }
}
