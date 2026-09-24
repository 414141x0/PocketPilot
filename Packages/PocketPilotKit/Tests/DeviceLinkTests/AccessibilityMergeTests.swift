import AgentCore
import CoreGraphics
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

        let merged = Screen(screenshot: .blank, merging: nodes, onto: [safariText, searchText, clockText]).elements

        #expect(merged.map(\.label) == ["Safari", "Search", "9:41"])
        #expect(merged.map(\.role) == [.button, .textField, .text])
        #expect(merged.map(\.id) == [1, 2, 3])
        #expect(merged[0].frame == safariText.frame)
        #expect(merged[1].traits == .selected)
    }

    @Test func prefersExactMatchOverContainment() {
        let longer = Element(id: 4, role: .text, label: "Safari Settings", frame: .fullScreen)
        let merged = Screen(screenshot: .blank, merging: [AccessibilityNode(role: "Button", label: "Safari")], onto: [longer, safariText]).elements

        #expect(merged.first?.frame == safariText.frame)
    }

    @Test func listsUnmatchedNodesAsUnlocatedAndDropsIgnored() {
        let nodes = [
            AccessibilityNode(role: "Button", label: "Safari", ignored: true),
            AccessibilityNode(role: "Button", label: "Share"),
        ]

        let screen = Screen(screenshot: .blank, merging: nodes, onto: [safariText])

        #expect(screen.elements.map(\.role) == [.text])
        #expect(screen.unlocated == [#"button "Share""#])
        #expect(screen.outline().hasSuffix(#"Also on screen, position unknown (tap them by point): button "Share""#))
    }

    @Test(arguments: [
        ("Search Field", Element.Role.textField), ("Static Text", .text), ("Button", .button),
        ("Switch Button", .toggle), ("Tab Bar Button", .tab), ("Heading", .header), ("Group", .other),
    ])
    func mapsRoleNames(_ name: String, _ role: Element.Role) {
        #expect(Element.Role(accessibilityRole: name) == role)
    }
}

private extension Screenshot {
    static var blank: Screenshot {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return Screenshot(image: context.makeImage()!)
    }
}

@Suite struct DuplicateLabelTests {
    @Test func repeatedLabelsPairInOrder() {
        let upper = Element(id: 1, role: .text, label: "Close", frame: Rect(x: 0.8, y: 0.1, width: 0.1, height: 0.02))
        let lower = Element(id: 2, role: .text, label: "Close", frame: Rect(x: 0.8, y: 0.6, width: 0.1, height: 0.02))
        let nodes = [AccessibilityNode(role: "Button", label: "Close"), AccessibilityNode(role: "Button", label: "Close")]

        let screen = Screen(screenshot: .blank, merging: nodes, onto: [upper, lower])

        #expect(screen.elements.map(\.frame) == [upper.frame, lower.frame])
        #expect(screen.unlocated.isEmpty)
    }
}
