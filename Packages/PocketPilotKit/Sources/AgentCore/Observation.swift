import Foundation

/// What the agent can perceive at one moment: pixels plus, when available, semantics.
public struct Observation: Sendable {
    public var screenshot: Screenshot
    public var elements: [Element]

    public init(screenshot: Screenshot, elements: [Element] = []) {
        self.screenshot = screenshot
        self.elements = elements
    }

    public subscript(id: Element.ID) -> Element? {
        elements.first { $0.id == id }
    }
}

public struct Screenshot: Sendable {
    /// PNG-encoded image data.
    public var png: Data
    /// Size in pixels, used by models that reason in image coordinates.
    public var width: Int
    public var height: Int

    public init(png: Data, width: Int, height: Int) {
        self.png = png
        self.width = width
        self.height = height
    }
}

/// One accessibility element, flattened out of the device's accessibility hierarchy.
public struct Element: Sendable, Hashable, Identifiable, Codable {
    /// Stable only within a single ``Observation``.
    public var id: Int
    public var role: Role
    public var label: String
    public var value: String?
    public var frame: Rect

    public init(id: Int, role: Role, label: String, value: String? = nil, frame: Rect) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.frame = frame
    }

    public enum Role: String, Sendable, Hashable, Codable {
        case button, link, text, textField, image, toggle, slider, tab, cell, header, keyboardKey, other
    }
}
