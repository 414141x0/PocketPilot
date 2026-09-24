import AgentCore

/// One node of the device's accessibility hierarchy. The daemon exposes no geometry,
/// so nodes gain frames only by matching recognized on-screen text.
struct AccessibilityNode: Sendable, Hashable, Decodable {
    var role: String?
    var label: String?
    var value: String?
    var traits: [String] = []
    var ignored = false
}

extension Screen {
    /// A screen that combines accessibility semantics with OCR geometry.
    ///
    /// Each labeled node takes the frame of the recognized text that reads the same,
    /// preferring an exact match over containment. Text no node claims stays as plain text.
    /// Labeled nodes with no matching text, typically icon-only controls, are listed as unlocated.
    init(screenshot: Screenshot, merging nodes: [AccessibilityNode], onto recognized: [Element]) {
        var unclaimed = recognized
        var merged: [Element] = []
        var unlocated: [String] = []

        for node in nodes where !node.ignored {
            guard let label = node.label?.normalizedForMatching, !label.isEmpty else { continue }
            let index = unclaimed.firstIndex { $0.label.normalizedForMatching == label }
                ?? unclaimed.firstIndex { $0.label.normalizedForMatching.overlaps(label) }
            guard let index else {
                if let label = node.label {
                    unlocated.append("\(Element.Role(accessibilityRole: node.role ?? "").rawValue) \"\(label)\"")
                }
                continue
            }

            let text = unclaimed.remove(at: index)
            merged.append(Element(
                id: merged.count + 1,
                role: Element.Role(accessibilityRole: node.role ?? ""),
                label: node.label ?? text.label,
                value: node.value,
                frame: text.frame,
                traits: Element.Traits(accessibilityTraits: node.traits)
            ))
        }

        for text in unclaimed {
            var text = text
            text.id = merged.count + 1
            merged.append(text)
        }
        self.init(screenshot: screenshot, elements: merged, unlocated: unlocated)
    }
}

extension Element.Role {
    /// Maps the daemon's human-readable role names, such as "Search Field" or "Static Text".
    init(accessibilityRole role: String) {
        let role = role.lowercased()
        // Most specific first: "Switch Button" is a toggle and "Tab Bar Button" a tab, not plain buttons.
        let rules: [(keywords: [String], role: Self)] = [
            (["switch", "toggle"], .toggle),
            (["tab"], .tab),
            (["field", "search"], .textField),
            (["slider", "adjustable"], .slider),
            (["link"], .link),
            (["key"], .keyboardKey),
            (["button"], .button),
            (["cell"], .cell),
            (["header", "heading"], .header),
            (["image", "icon"], .image),
            (["text"], .text),
        ]
        self = rules.first { $0.keywords.contains(where: role.contains) }?.role ?? .other
    }
}

extension Element.Traits {
    init(accessibilityTraits traits: [String]) {
        let traits = Set(traits.map { $0.lowercased() })
        self = []
        if traits.contains("not enabled") || traits.contains("disabled") { insert(.disabled) }
        if traits.contains("selected") { insert(.selected) }
        if traits.contains("focused") { insert(.focused) }
    }
}

private extension String {
    var normalizedForMatching: String {
        lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Containment in either direction, ignoring fragments too short to be meaningful.
    func overlaps(_ other: String) -> Bool {
        min(count, other.count) >= 3 && (contains(other) || other.contains(self))
    }
}
