import AgentCore
import Foundation

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
    /// Labeled controls with no matching text, typically icon-only buttons, are listed as unlocated.
    /// Unmatched static content is dropped: the hierarchy includes off-screen rows, which OCR never sees.
    init(screenshot: Screenshot, merging nodes: [AccessibilityNode], onto recognized: [Element]) {
        var unclaimed = recognized
        var merged: [Element] = []
        var unlocated: [String] = []

        for node in nodes where !node.ignored {
            let cleanLabel = node.label.map(Self.withoutHints)
            guard let label = cleanLabel?.normalizedForMatching, !label.isEmpty else { continue }
            let index = unclaimed.firstIndex { $0.label.normalizedForMatching == label }
                ?? unclaimed.firstIndex { $0.label.normalizedForMatching.overlaps(label) }
            guard let index else {
                let role = Element.Role(accessibilityRole: node.role ?? "")
                if let label = cleanLabel, role.isActionable {
                    unlocated.append("\(role.rawValue) \"\(label)\"")
                }
                continue
            }

            let text = unclaimed.remove(at: index)
            merged.append(Element(
                id: merged.count + 1,
                role: Element.Role(accessibilityRole: node.role ?? ""),
                label: cleanLabel ?? text.label,
                value: node.value,
                frame: text.frame,
                traits: Element.Traits(accessibilityTraits: node.traits)
            ))
        }

        for text in unclaimed where text.isLegible {
            var text = text
            text.id = merged.count + 1
            merged.append(text)
        }
        self.init(screenshot: screenshot, elements: merged, unlocated: unlocated)
    }

    /// Hint phrases VoiceOver appends to labels, which say nothing about what an element is.
    private static let hintPhrases = ["updates frequently", "in icloud", "double tap", "double-tap"]

    static func withoutHints(_ label: String) -> String {
        label.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { part in !hintPhrases.contains { part.lowercased().hasPrefix($0) } }
            .joined(separator: ", ")
    }
}

private extension Element {
    /// Recognized text worth listing: below the status bar and made of real words, not icon glyph fragments.
    var isLegible: Bool {
        frame.center.y > 0.045 && label.filter(\.isLetter).count >= 3
    }
}

extension Element.Role {
    /// Whether a model would act on an element of this role rather than just read it.
    var isActionable: Bool {
        switch self {
        case .button, .link, .textField, .toggle, .slider, .tab, .cell: true
        case .text, .image, .header, .keyboardKey, .other: false
        }
    }

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
        // Home-screen icons and folders carry a label but no role description, and are tappable.
        guard !role.isEmpty else { self = .button; return }
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
