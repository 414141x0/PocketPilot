import Foundation
import Testing
@testable import AgentCore

@Suite struct AgentTests {
    @Test func completesWhenPilotIsDone() async throws {
        let device = FakeDevice()
        let pilot = ScriptedPilot(.tap(.element(1)), .type("hello"), .done(summary: "Sent"))
        let agent = Agent(device: device, pilot: pilot, settle: .zero)

        let outcome = try await agent.run("Send hello")

        #expect(outcome == .completed(summary: "Sent"))
        #expect(await device.gestures == [.tap(Point(x: 0.5, y: 0.5)), .type("hello")])
    }

    @Test func feedsUnknownElementBackToPilot() async throws {
        let pilot = ScriptedPilot(.tap(.element(99)), .giveUp(reason: "stuck"))
        let agent = Agent(device: FakeDevice(), pilot: pilot, settle: .zero)

        let outcome = try await agent.run("Tap something")

        #expect(outcome == .abandoned(reason: "stuck"))
        #expect(await pilot.lastHistory.first?.failure == ResolutionError.unknownElement(99).description)
    }

    @Test func throwsUnrecoverableDeviceErrors() async {
        let agent = Agent(device: FakeDevice(failure: .tunnelUnavailable), pilot: ScriptedPilot(.tap(.element(1))), settle: .zero)

        await #expect(throws: DeviceError.tunnelUnavailable) {
            try await agent.run("Anything")
        }
    }

    @Test func stopsAtStepLimit() async throws {
        let pilot = ScriptedPilot(repeating: .wait(seconds: 0))
        let outcome = try await Agent(device: FakeDevice(), pilot: pilot, maxSteps: 3, settle: .zero).run("Loop")

        #expect(outcome == .outOfSteps)
    }

    @Test(arguments: Direction.allCases)
    func scrollMovesFingerAgainstDirection(_ direction: Direction) throws {
        guard case .swipe(let start, let end, _) = Gesture.swipe(direction, in: .fullScreen) else {
            Issue.record("Expected a swipe")
            return
        }
        switch direction {
        case .down: #expect(start.y > end.y)
        case .up: #expect(start.y < end.y)
        case .right: #expect(start.x > end.x)
        case .left: #expect(start.x < end.x)
        }
    }

    @Test func outlineUsesGridCoordinates() {
        let element = Element(id: 3, role: .button, label: "Send", frame: Rect(x: 0.8, y: 0.9, width: 0.1, height: 0.02))
        #expect(element.outline == #"[3] button "Send" @(850,910)"#)
    }
}

private actor FakeDevice: Device {
    private(set) var gestures: [Gesture] = []
    private let failure: DeviceError?

    init(failure: DeviceError? = nil) { self.failure = failure }

    func observe() throws(DeviceError) -> Screen {
        Screen(
            screenshot: Screenshot(png: Data(), width: 1, height: 1),
            elements: [Element(id: 1, role: .button, label: "OK", frame: Rect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))]
        )
    }

    func perform(_ gesture: Gesture) throws(DeviceError) {
        if let failure { throw failure }
        gestures.append(gesture)
    }
}

private actor ScriptedPilot: Pilot {
    private var script: [Action]
    private let fallback: Action?
    private(set) var lastHistory: [Turn] = []

    init(_ script: Action...) { self.script = script; fallback = nil }
    init(repeating action: Action) { script = []; fallback = action }

    func decide(_ step: Step) -> Decision {
        lastHistory = step.history
        let action = script.isEmpty ? fallback! : script.removeFirst()
        return Decision(action: action)
    }
}
