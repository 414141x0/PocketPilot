import AgentCore
import DeviceLink
import Foundation

/// Keeps PocketPilot's own Picture-in-Picture card out of the agent's view.
///
/// iOS can bring a stashed PiP window back, so every observation checks for the card:
/// it is flicked back into the screen edge when visible, and anything inside it is dropped
/// so pilots never read their own status text as screen content.
nonisolated struct PiPShieldedDevice: Device {
    let base: Phone

    func observe() async throws(DeviceError) -> Screen {
        var screen = try await base.observe()
        if let card = PiPCard(on: screen) {
            try await base.perform(.swipe(from: card.flickStart, to: Point(x: 0, y: card.flickStart.y), duration: .milliseconds(120)))
            try? await Task.sleep(for: .milliseconds(600))
            screen = try await base.observe()
        }
        if let card = PiPCard(on: screen) {
            screen.elements.removeAll { card.contains($0) }
        }
        return screen
    }

    func perform(_ gesture: Gesture) async throws(DeviceError) {
        try await base.perform(gesture)
    }

    func installedApps() async throws(DeviceError) -> [InstalledApp] {
        try await base.installedApps()
    }

    func frontmostApp() async throws(DeviceError) -> FrontmostApp? {
        try await base.frontmostApp()
    }
}

/// The on-screen extent of the PiP status card, found by its marker and "to stop" lines.
nonisolated struct PiPCard {
    static let marker = "PocketPilot"

    let top: Double
    let bottom: Double

    init?(on screen: Screen) {
        guard let marker = screen.elements.first(where: { $0.label.localizedCaseInsensitiveContains(Self.marker) }) else {
            return nil
        }
        let stop = screen.elements.first { $0.label.localizedCaseInsensitiveContains("to stop") && $0.frame.origin.y > marker.frame.origin.y }
        top = marker.frame.origin.y - 0.02
        bottom = (stop.map { $0.frame.origin.y + $0.frame.height } ?? marker.frame.origin.y + 0.2) + 0.02
    }

    /// The card spans most of the width; a long, fast flick from its middle stashes it.
    var flickStart: Point { Point(x: 0.5, y: (top + bottom) / 2) }

    func contains(_ element: Element) -> Bool {
        (top...bottom).contains(element.frame.center.y)
    }
}
