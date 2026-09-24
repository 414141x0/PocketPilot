import AgentCore
import Testing
@testable import DeviceLink

@Suite struct AccessibilityMergeTests {
    let safariText = Element(id: 1, role: .text, label: "Safari", frame: Rect(x: 0.3, y: 0.9, width: 0.1, height: 0.02))
    let searchText = Element(id: 2, role: .text, label: "Search", frame: Rect(x: 0.4, y: 0.8, width: 0.2, height: 0.03))
    let clockText = Element(id: 3, role: .text, label: "9:41", frame: Rect(x: 0.1, y: 0.01, width: 0.1, height: 0.02))

    @Test func nodesTakeFramesFromMatchingText() {
        let nodes = [
            AccessibilityNode(role: "Button", label: "Safari"),
            AccessibilityNode(role: "Search Field", label: "Search", traits: ["Selected"]),
        ]

        let merged = [Element].merging(nodes, onto: [safariText, searchText, clockText])

        #expect(merged.map(\.label) == ["Safari", "Search", "9:41"])
        #expect(merged.map(\.role) == [.button, .textField, .text])
        #expect(merged.map(\.id) == [1, 2, 3])
        #expect(merged[0].frame == safariText.frame)
        #expect(merged[1].traits == .selected)
    }

    @Test func prefersExactMatchOverContainment() {
        let longer = Element(id: 4, role: .text, label: "Safari Settings", frame: .fullScreen)
        let merged = [Element].merging([AccessibilityNode(role: "Button", label: "Safari")], onto: [longer, safariText])

        #expect(merged.first?.frame == safariText.frame)
    }

    @Test func dropsIgnoredAndUnmatchedNodes() {
        let nodes = [
            AccessibilityNode(role: "Button", label: "Safari", ignored: true),
            AccessibilityNode(role: "Image", label: "Wallpaper"),
        ]

        let merged = [Element].merging(nodes, onto: [safariText])

        #expect(merged.map(\.role) == [.text])
    }

    @Test(arguments: [
        ("Search Field", Element.Role.textField), ("Static Text", .text), ("Button", .button),
        ("Switch Button", .toggle), ("Tab Bar Button", .tab), ("Heading", .header), ("Group", .other),
    ])
    func mapsRoleNames(_ name: String, _ role: Element.Role) {
        #expect(Element.Role(accessibilityRole: name) == role)
    }
}
